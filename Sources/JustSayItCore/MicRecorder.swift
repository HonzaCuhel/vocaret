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
/// - to-file: written as a native-format WAV for later batch transcription
public final class MicRecorder {
    public static let whisperSampleRate: Double = 16_000

    public private(set) var isRunning = false

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var samples: [Float] = []
    private let sampleLock = NSLock()

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
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }

        if let fileURL {
            file = try AVAudioFile(
                forWriting: fileURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: inputFormat.sampleRate,
                    AVNumberOfChannelsKey: inputFormat.channelCount,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } else {
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.whisperSampleRate,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
                throw AudioCaptureError.formatUnsupported
            }
            self.converter = converter
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRunning = true
    }

    private func process(buffer: AVAudioPCMBuffer) {
        if let file {
            do {
                try file.write(from: buffer)
            } catch {
                Log.error("Mic file write failed: \(error.localizedDescription)")
            }
            return
        }

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

        if converted.frameLength > 0, let channelData = converted.floatChannelData {
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
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        file = nil
        isRunning = false

        sampleLock.lock()
        defer { sampleLock.unlock() }
        let result = samples
        samples = []
        return result
    }
}
