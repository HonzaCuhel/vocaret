import AVFoundation

/// Pulls recognition-ready audio from disk with constant-sized buffers, even
/// when the recovery source is a long native-rate stereo WAV.
final class MeetingAudioFileReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let outputFormat: AVAudioFormat

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(ceil(file.processingFormat.sampleRate / 4)) + 64)
        else { throw AudioCaptureError.formatUnsupported }
        self.converter = converter
        self.input = input
        outputFormat = target
    }

    func next() throws -> [Float]? {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_000) else {
                throw AudioCaptureError.formatUnsupported
            }
            var readError: Error?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { [file, input] count, status in
                do {
                    let remaining = file.length - file.framePosition
                    guard remaining > 0 else { status.pointee = .endOfStream; return nil }
                    let frames = min(AVAudioFramePosition(min(count, input.frameCapacity)), remaining)
                    try file.read(into: input, frameCount: AVAudioFrameCount(frames))
                    guard input.frameLength > 0 else { status.pointee = .endOfStream; return nil }
                    status.pointee = .haveData
                    return input
                } catch {
                    readError = error
                    status.pointee = .noDataNow
                    return nil
                }
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? AudioCaptureError.formatUnsupported as NSError }
            try Task.checkCancellation()
            guard output.frameLength > 0, let data = output.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
        }
    }
}
