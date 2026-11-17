import XCTest
@testable import VocaretCore

final class SonioxMeetingSessionTests: XCTestCase {
    func testBothTracksKeepIndependentReturningSpeakersAndFinalText() async {
        let mic = FakeMeetingStream(segments: [.init(speakerID: "1", start: 0, end: 1, text: "Moje otázka")])
        let system = FakeMeetingStream(segments: [
            .init(speakerID: "1", start: 1, end: 2, text: "First"),
            .init(speakerID: "2", start: 2, end: 3, text: "Second"),
            .init(speakerID: "1", start: 3, end: 4, text: "First again"),
        ])
        let session = SonioxMeetingSession(microphone: mic, system: system)
        session.append([0.1], speaker: .me)
        session.append([0.1], speaker: .them)
        let result = await session.finish()
        XCTAssertFalse(result.needsRecovery)
        XCTAssertEqual(result.mine.first?.speaker, .participant(source: .microphone, id: "1"))
        XCTAssertEqual(result.theirs.map(\.speaker), [
            .participant(source: .system, id: "1"), .participant(source: .system, id: "2"),
            .participant(source: .system, id: "1"),
        ])
        XCTAssertEqual(result.turns.count, 4)
        let starts = await system.starts
        XCTAssertEqual(starts, 1, "One continuous speaker context per track")
    }

    func testFailureRetainsOnlyFinalPrefixAndOtherTrack() async {
        let mic = FakeMeetingStream(segments: [.init(speakerID: nil, start: 0, end: 1, text: "Known final")], failOnAppend: true)
        let system = FakeMeetingStream(segments: [.init(speakerID: "2", start: 0, end: 1, text: "Other track")])
        let session = SonioxMeetingSession(microphone: mic, system: system)
        session.append([0.1], speaker: .me)
        session.append([0.1], speaker: .them)
        let result = await session.finish()
        XCTAssertEqual(result.failedSpeakers, [.me])
        XCTAssertEqual(result.mine.map(\.text), ["Known final"])
        XCTAssertEqual(result.mine.first?.speaker, .unidentified(source: .microphone))
        XCTAssertEqual(result.theirs.map(\.text), ["Other track"])
    }

    func testEmptyMeetingDoesNotOpenPaidConnections() async {
        let mic = FakeMeetingStream(segments: [])
        let system = FakeMeetingStream(segments: [])
        let session = SonioxMeetingSession(microphone: mic, system: system)
        let result = await session.finish()
        XCTAssertTrue(result.turns.isEmpty)
        let counts = await (mic.starts, system.starts)
        XCTAssertEqual(counts.0 + counts.1, 0)
    }

    func testQueueOverflowRequestsWavRecoveryForBothTracks() async {
        let session = SonioxMeetingSession(
            microphone: FakeMeetingStream(segments: []), system: FakeMeetingStream(segments: []),
            maxBufferedSamples: 2
        )
        session.append([0.1, 0.1, 0.1], speaker: .me)
        let result = await session.finish()
        XCTAssertEqual(result.failedSpeakers, [.me, .them])
    }

    func testCancellationClosesBothStreams() async {
        let mic = FakeMeetingStream(segments: [])
        let system = FakeMeetingStream(segments: [])
        let session = SonioxMeetingSession(microphone: mic, system: system)
        session.cancel()
        _ = await session.finish()
        let closed = await (mic.cancelled, system.cancelled)
        XCTAssertTrue(closed.0 && closed.1)
    }
}

private actor FakeMeetingStream: DiarizedTranscriptionSession {
    let segments: [SonioxDiarizedSegment]
    let failOnAppend: Bool
    var starts = 0
    var cancelled = false
    var callback: (@Sendable ([SonioxDiarizedSegment]) async -> Void)?

    init(segments: [SonioxDiarizedSegment], failOnAppend: Bool = false) {
        self.segments = segments
        self.failOnAppend = failOnAppend
    }
    func start(onPartial: @escaping @Sendable (String) async -> Void,
               onDiarizedSegments: (@Sendable ([SonioxDiarizedSegment]) async -> Void)?) async throws {
        starts += 1
        callback = onDiarizedSegments
    }
    func append(_ samples: [Float]) async throws {
        if failOnAppend { throw SonioxTranscriberError.prematureClosure }
        await callback?(segments)
    }
    func finish() async throws -> String { segments.map(\.text).joined(separator: " ") }
    func finalizedDiarizedSegments() -> [SonioxDiarizedSegment] { segments }
    func cancel() { cancelled = true }
}
