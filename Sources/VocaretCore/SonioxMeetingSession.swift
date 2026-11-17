import Foundation

protocol DiarizedTranscriptionSession: Sendable {
    func start(onPartial: @escaping @Sendable (String) async -> Void,
               onDiarizedSegments: (@Sendable ([SonioxDiarizedSegment]) async -> Void)?) async throws
    func append(_ samples: [Float]) async throws
    func finish() async throws -> String
    func finalizedDiarizedSegments() async -> [SonioxDiarizedSegment]
    func cancel() async
}

extension SonioxTranscriber: DiarizedTranscriptionSession {}

/// One long-lived recognition context per source, never one per utterance.
/// Capture callbacks only enqueue bounded audio; WAVs remain the recovery source.
final class SonioxMeetingSession: MeetingSession {
    private let buffer: MeetingAudioBuffer
    private let streams: [Speaker: any DiarizedTranscriptionSession]
    private let task: Task<MeetingTranscriptionResult, Never>

    convenience init(configuration: SonioxConfiguration,
                     onUpdate: @escaping @Sendable (MeetingTranscriptionResult) async -> Void) {
        self.init(microphone: SonioxTranscriber(configuration: configuration),
                  system: SonioxTranscriber(configuration: configuration), onUpdate: onUpdate)
    }

    init(microphone: any DiarizedTranscriptionSession, system: any DiarizedTranscriptionSession,
         maxBufferedSamples: Int = 16_000 * 120,
         onUpdate: @escaping @Sendable (MeetingTranscriptionResult) async -> Void = { _ in }) {
        let buffer = MeetingAudioBuffer(maxSamples: maxBufferedSamples)
        let streams: [Speaker: any DiarizedTranscriptionSession] = [.me: microphone, .them: system]
        self.buffer = buffer
        self.streams = streams
        task = Task.detached(priority: .userInitiated) {
            let state = SonioxMeetingState(onUpdate: onUpdate)
            var started = Set<Speaker>()
            var failed = Set<Speaker>()
            for await packet in buffer.stream {
                buffer.consumed(packet)
                guard !Task.isCancelled else { break }
                guard let stream = streams[packet.speaker] else { continue }
                await state.setOffset(packet.trackOffset, track: packet.speaker)
                guard !failed.contains(packet.speaker) else { continue }
                do {
                    if !started.contains(packet.speaker) {
                        let track = packet.speaker
                        try await stream.start(onPartial: { _ in }, onDiarizedSegments: { segments in
                            guard !Task.isCancelled else { return }
                            await state.update(segments, track: track)
                        })
                        started.insert(track)
                    }
                    try await stream.append(packet.samples)
                } catch {
                    guard !Task.isCancelled else { break }
                    failed.insert(packet.speaker)
                    await state.update(await stream.finalizedDiarizedSegments(), track: packet.speaker)
                    await state.fail(packet.speaker)
                    await stream.cancel()
                    Log.warn("Soniox meeting track interrupted; WAV retained for local recovery")
                }
            }
            if Task.isCancelled {
                for stream in streams.values { await stream.cancel() }
                return await state.result
            }
            // Each transport has its own bounded finish; retain final-only text
            // even when finalization fails instead of treating tentative text as final.
            for track in [Speaker.me, .them] where started.contains(track) && !failed.contains(track) {
                guard let stream = streams[track] else { continue }
                do { _ = try await stream.finish() }
                catch {
                    await state.fail(track)
                    await stream.cancel()
                }
                await state.update(await stream.finalizedDiarizedSegments(), track: track)
            }
            if buffer.hasOverflowed {
                await state.fail(.me)
                await state.fail(.them)
            }
            return await state.result
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
        // Closing transports promptly unblocks any in-flight send.
        Task { [streams] in for stream in streams.values { await stream.cancel() } }
    }
}

private actor SonioxMeetingState {
    var result = MeetingTranscriptionResult()
    let onUpdate: @Sendable (MeetingTranscriptionResult) async -> Void

    init(onUpdate: @escaping @Sendable (MeetingTranscriptionResult) async -> Void) {
        self.onUpdate = onUpdate
    }

    func setOffset(_ offset: Double, track: Speaker) { result.trackOffsets[track] = offset }

    func update(_ segments: [SonioxDiarizedSegment], track: Speaker) async {
        let source: SpeakerSource = track == .me ? .microphone : .system
        let offset = result.trackOffsets[track] ?? 0
        let aligned = segments.map { segment in
            SpokenSegment(start: segment.start + offset, end: segment.end + offset, text: segment.text,
                          speaker: segment.speakerID.map { .participant(source: source, id: $0) }
                              ?? .unidentified(source: source))
        }
        if track == .me { result.mine = aligned } else { result.theirs = aligned }
        await onUpdate(result)
    }

    func fail(_ track: Speaker) async {
        result.failedSpeakers.insert(track)
        await onUpdate(result)
    }
}
