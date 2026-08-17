import AVFoundation

public enum AudioCaptureError: Error, LocalizedError {
    case microphoneUnavailable
    case formatUnsupported
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "No usable microphone input (is microphone permission granted?)"
        case .formatUnsupported:
            return "Unsupported audio format"
        case .tapCreationFailed(let status):
            return "Could not create system audio tap (OSStatus \(status))"
        case .aggregateCreationFailed(let status):
            return "Could not create aggregate audio device (OSStatus \(status))"
        case .ioProcFailed(let status):
            return "Could not start audio IO (OSStatus \(status))"
        }
    }
}

/// Captures the default microphone. Two modes:
/// - in-memory: converted on the fly to 16 kHz mono Float32 (Whisper's input format)
/// - to-file: written as a WAV in the format the mic had at start
///
/// Both modes always run the input through an AVAudioConverter to a fixed
/// target format, so when the input device changes mid-recording (AirPods
/// connect, headset unplugged → `AVAudioEngineConfigurationChange`) we can
/// rebuild the converter for the new input format and keep recording into
/// the same buffer/file instead of silently stopping.
public final class MicRecorder {
    public static let whisperSampleRate: Double = 16_000

    public private(set) var isRunning = false
    /// Called (on the main queue) if the engine had to be restarted after an
    /// audio-route change, or stopped because it could not be restarted.
    public var onInterrupted: ((Error?) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private var samples: [Float] = []
    private let sampleLock = NSLock()
    private var configObserver: NSObjectProtocol?

    public init() {}

    public func startInMemory() throws {
        try start(fileURL: nil)
    }

    public func startToFile(url: URL) throws {
        try start(fileURL: url)
    }

    private func start(fileURL: URL?) throws {
        guard !isRunning else { return }
        sampleLock.lock()
        samples.removeAll()
        sampleLock.unlock()

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }

        let target: AVAudioFormat
        if let fileURL {
            // Keep the mic's native rate but always mono Float32 — smaller
            // files, and Whisper mixes to mono anyway.
            guard let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) else { throw AudioCaptureError.formatUnsupported }
            file = try AVAudioFile(
                forWriting: fileURL,
                settings: mono.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            target = mono
        } else {
            guard let whisper = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.whisperSampleRate,
                channels: 1,
                interleaved: false
            ) else { throw AudioCaptureError.formatUnsupported }
            target = whisper
        }
        targetFormat = target
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            file = nil
            throw AudioCaptureError.formatUnsupported
        }
        self.converter = converter

        try installTapAndStart(engine)
        self.engine = engine
        isRunning = true
        observeConfigurationChanges(of: engine)
    }

    private func installTapAndStart(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// The engine stops on route changes; rebuild the converter for the new
    /// input format and restart so the recording continues.
    private func handleConfigurationChange() {
        guard isRunning, let engine, let targetFormat else { return }
        engine.inputNode.removeTap(onBus: 0)
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0,
              let newConverter = AVAudioConverter(from: newFormat, to: targetFormat) else {
            Log.error("Mic route changed to an unusable format; recording stopped")
            onInterrupted?(AudioCaptureError.microphoneUnavailable)
            return
        }
        converter = newConverter
        do {
            try installTapAndStart(engine)
            Log.info("Mic route changed (\(Int(newFormat.sampleRate)) Hz, \(newFormat.channelCount) ch); recording continues")
            onInterrupted?(nil)
        } catch {
            Log.error("Mic engine restart failed: \(error.localizedDescription)")
            onInterrupted?(error)
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return
        }

        // Feed exactly this buffer, then report "no data for now" so the
        // converter keeps its resampling state alive for the next tap callback.
        var consumed = false
        converter.convert(to: converted, error: nil) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard converted.frameLength > 0 else { return }

        if let file {
            do {
                try file.write(from: converted)
            } catch {
                Log.error("Mic file write failed: \(error.localizedDescription)")
            }
            return
        }
        if let channelData = converted.floatChannelData {
            sampleLock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(converted.frameLength)))
            sampleLock.unlock()
        }
    }

    /// Stops capture. Returns the accumulated 16 kHz samples (in-memory mode)
    /// or an empty array (file mode — the WAV is already on disk).
    @discardableResult
    public func stop() -> [Float] {
        guard isRunning else { return [] }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        targetFormat = nil
        file = nil
        isRunning = false
        onInterrupted = nil

        sampleLock.lock()
        defer { sampleLock.unlock() }
        let result = samples
        samples = []
        return result
    }
}
