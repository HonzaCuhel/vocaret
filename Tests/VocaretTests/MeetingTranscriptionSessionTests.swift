import XCTest
@testable import VocaretCore

final class MeetingTranscriptionSessionTests: XCTestCase {
    private let voice = [Float](repeating: 0.1, count: 16_000)

    func testPublishesDuringCaptureThenFlushesBothFinalTails() async {
        let published = expectation(description: "live turn before stop")
        let session = MeetingTranscriptionSession(decode: { samples, offset in
            [SpokenSegment(start: offset, end: offset + Double(samples.count) / 16_000, text: "Ahoj hello")]
        }, onUpdate: { result in
            if !result.mine.isEmpty && result.theirs.isEmpty { published.fulfill() }
        })
        session.append(voice + [Float](repeating: 0, count: 24_000), speaker: .me)
        await fulfillment(of: [published], timeout: 3)
        session.append(voice, speaker: .them)
        let result = await session.finish()
        XCTAssertEqual(result.mine.count, 1)
        XCTAssertEqual(result.theirs.count, 1)
        XCTAssertFalse(result.needsRecovery)
    }

    func testFailureKeepsOtherSpeakerAndMarksRecovery() async {
        let session = MeetingTranscriptionSession(decode: { _, _ in throw TestError.failed })
        session.append(voice, speaker: .me)
        let result = await session.finish()
        XCTAssertTrue(result.failedSpeakers.contains(.me))
        XCTAssertFalse(result.failedSpeakers.contains(.them))
    }

    func testBoundedBufferReportsOverflowRatherThanSilentLoss() async {
        let buffer = MeetingAudioBuffer(maxSamples: 100)
        XCTAssertTrue(buffer.append([Float](repeating: 0.1, count: 60), speaker: .me))
        XCTAssertFalse(buffer.append([Float](repeating: 0.1, count: 60), speaker: .them))
        XCTAssertTrue(buffer.hasOverflowed)
        XCTAssertLessThanOrEqual(buffer.bufferedSamples, 100)
        buffer.finish()
    }

    func testEmptyMeetingNeverDecodes() async {
        let session = MeetingTranscriptionSession(decode: { _, _ in
            XCTFail("Silence must not invoke the model")
            return []
        })
        session.append([Float](repeating: 0, count: 48_000), speaker: .me)
        let result = await session.finish()
        XCTAssertTrue(result.mine.isEmpty)
        XCTAssertFalse(result.needsRecovery)
    }

    func testCancellationDoesNotPublishLateResult() async {
        let entered = expectation(description: "decoder started")
        let session = MeetingTranscriptionSession(decode: { _, _ in
            entered.fulfill()
            try await Task.sleep(nanoseconds: 100_000_000)
            return [SpokenSegment(start: 0, end: 1, text: "late")]
        }, onUpdate: { _ in XCTFail("cancelled results must not reach the UI") })
        session.append(voice + [Float](repeating: 0, count: 24_000), speaker: .me)
        await fulfillment(of: [entered], timeout: 3)
        session.cancel()
        let result = await session.finish()
        XCTAssertTrue(result.mine.isEmpty)
    }

    func testRecoveredTrackRetainsItsClockOffset() {
        var result = MeetingTranscriptionResult(
            mine: [SpokenSegment(start: 1, end: 2, text: "earlier")],
            failedSpeakers: [.them], trackOffsets: [.them: 4.5]
        )
        result.recover(.them, from: [SpokenSegment(start: 0, end: 1, text: "later")])
        XCTAssertEqual(result.theirs.first?.start, 4.5)
        XCTAssertEqual(result.theirs.first?.end, 5.5)
        XCTAssertEqual(result.turns.map(\.text), ["earlier", "later"])
        XCTAssertFalse(result.needsRecovery)
    }

    enum TestError: Error { case failed }
}
