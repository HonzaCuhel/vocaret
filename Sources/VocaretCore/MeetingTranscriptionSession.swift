import Foundation

struct MeetingTranscriptionResult: Sendable {
    var mine: [SpokenSegment] = []
    var theirs: [SpokenSegment] = []
    var failedSpeakers: Set<Speaker> = []
    var trackOffsets: [Speaker: Double] = [:]

    mutating func recover(_ speaker: Speaker, from segments: [SpokenSegment]) {
        let offset = trackOffsets[speaker] ?? 0
        let aligned = segments.map {
            SpokenSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text)
        }
        if speaker == .me { mine = aligned } else { theirs = aligned }
        failedSpeakers.remove(speaker)
    }
    var needsRecovery: Bool { !failedSpeakers.isEmpty }
    var turns: [MergedTurn] { TranscriptMerger.merge(mine: mine, theirs: theirs) }
}

/// Sample-count bounded bridge. Capture never waits for inference; the WAV is
/// the recovery source if a cold model or slow machine falls behind.
final class MeetingAudioBuffer: @unchecked Sendable {
    struct Packet: Sendable {
        let speaker: Speaker
        let samples: [Float]
        let trackOffset: Double
    }
    let stream: AsyncStream<Packet>
    private let continuation: AsyncStream<Packet>.Continuation
    private let lock = NSLock()
    private let maxSamples: Int
    private var count = 0
    private var overflowed = false
    private var closed = false
    private var origin: TimeInterval?
    private var trackOffsets: [Speaker: Double] = [:]

    init(maxSamples: Int = 16_000 * 120) {
        precondition(maxSamples > 0)
        self.maxSamples = maxSamples
        let pair = AsyncStream<Packet>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    @discardableResult
    func append(_ samples: [Float], speaker: Speaker) -> Bool {
        guard !samples.isEmpty else { return true }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        guard samples.count <= maxSamples - count else {
            overflowed = true
            closed = true
            continuation.finish()
            return false
        }
        let start = ProcessInfo.processInfo.systemUptime - Double(samples.count) / 16_000
        if origin == nil { origin = start }
        if trackOffsets[speaker] == nil { trackOffsets[speaker] = max(0, start - (origin ?? start)) }
        count += samples.count
        continuation.yield(Packet(speaker: speaker, samples: samples, trackOffset: trackOffsets[speaker] ?? 0))
        return true
    }

    func consumed(_ packet: Packet) {
        lock.lock(); defer { lock.unlock() }
        count -= packet.samples.count
    }

    var hasOverflowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return overflowed
    }

    var bufferedSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        continuation.finish()
    }
}

/// A single worker decodes both tracks sequentially. Inference runs off the
/// main actor, while capture continues into the bounded stream and WAV files.
final class MeetingTranscriptionSession: Sendable {
    typealias Decode = @Sendable ([Float], Double) async throws -> [SpokenSegment]
    private let buffer: MeetingAudioBuffer
    private let task: Task<MeetingTranscriptionResult, Never>

    init(
        prepare: @escaping @Sendable () async -> Void = {},
        release: @escaping @Sendable () async -> Void = {},
        decode: @escaping Decode,
        onUpdate: @escaping @Sendable (MeetingTranscriptionResult) async -> Void = { _ in }
    ) {
        let buffer = MeetingAudioBuffer()
        self.buffer = buffer
        task = Task.detached(priority: .userInitiated) {
            await prepare()
            var chunkers: [Speaker: StreamingUtteranceChunker] = [.me: .init(), .them: .init()]
            var offsets: [Speaker: Double] = [:]
            var result = MeetingTranscriptionResult()
            for await packet in buffer.stream {
                buffer.consumed(packet)
                guard !Task.isCancelled else { break }
                offsets[packet.speaker] = packet.trackOffset
                result.trackOffsets[packet.speaker] = packet.trackOffset
                let chunks = chunkers[packet.speaker, default: .init()].append(packet.samples)
                for chunk in chunks {
                    await Self.decode(chunk, speaker: packet.speaker, offset: packet.trackOffset,
                                      result: &result, using: decode, onUpdate: onUpdate)
                }
            }
            if !Task.isCancelled {
                for speaker in [Speaker.me, .them] {
                    for chunk in chunkers[speaker, default: .init()].finish() {
                        await Self.decode(chunk, speaker: speaker, offset: offsets[speaker] ?? 0,
                                          result: &result, using: decode, onUpdate: onUpdate)
                    }
                }
                if buffer.hasOverflowed {
                    result.failedSpeakers.formUnion([.me, .them])
                    await onUpdate(result)
                }
            }
            await release()
            return result
        }
    }

    private static func decode(
        _ chunk: MeetingAudioChunk, speaker: Speaker, offset: Double,
        result: inout MeetingTranscriptionResult, using decode: Decode,
        onUpdate: @Sendable (MeetingTranscriptionResult) async -> Void
    ) async {
        guard !Task.isCancelled, !result.failedSpeakers.contains(speaker) else { return }
        do {
            let segments = try await decode(chunk.samples, offset + Double(chunk.startSample) / 16_000)
            guard !Task.isCancelled else { return }
            if speaker == .me { result.mine += segments } else { result.theirs += segments }
            if !segments.isEmpty { await onUpdate(result) }
        } catch {
            guard !Task.isCancelled else { return }
            result.failedSpeakers.insert(speaker)
            Log.warn("Live meeting decode failed for \(speaker.label); recording retained for recovery")
            await onUpdate(result)
        }
    }

    func append(_ samples: [Float], speaker: Speaker) { buffer.append(samples, speaker: speaker) }
    func finish() async -> MeetingTranscriptionResult {
        buffer.finish()
        return await task.value
    }
    func cancel() {
        task.cancel()
        buffer.finish()
    }
}
