import XCTest
@testable import VocaretCore

final class LiveAudioChunkBufferTests: XCTestCase {
    func testOverflowFinishesStreamAndPreservesOldestAudio() async {
        let subject = LiveAudioChunkBuffer(capacity: 1)

        XCTAssertTrue(subject.yield([1]))
        XCTAssertFalse(subject.yield([2]))
        XCTAssertTrue(subject.hasOverflowed)

        var received: [[Float]] = []
        for await samples in subject.stream {
            received.append(samples)
        }
        XCTAssertEqual(received, [[1]])
    }

    func testExplicitFinishEndsWithoutReportingOverflow() async {
        let subject = LiveAudioChunkBuffer(capacity: 1)

        XCTAssertTrue(subject.yield([1]))
        subject.finish()

        var received: [[Float]] = []
        for await samples in subject.stream {
            received.append(samples)
        }
        XCTAssertEqual(received, [[1]])
        XCTAssertFalse(subject.hasOverflowed)
    }
}
