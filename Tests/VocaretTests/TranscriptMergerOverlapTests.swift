import XCTest
@testable import VocaretCore

final class TranscriptMergerOverlapTests: XCTestCase {
    func testLongOverlappingSpeakerDoesNotEraseOtherSpeakersTurnGap() {
        let first = Speaker.participant(source: .microphone, id: "1")
        let second = Speaker.participant(source: .system, id: "1")
        let turns = TranscriptMerger.merge(
            mine: [.init(start: 0, end: 100, text: "Long explanation", speaker: first)],
            theirs: [
                .init(start: 10, end: 11, text: "First interruption", speaker: second),
                .init(start: 30, end: 31, text: "Later interruption", speaker: second),
            ]
        )
        XCTAssertEqual(turns, [
            .init(speaker: first, start: 0, text: "Long explanation"),
            .init(speaker: second, start: 10, text: "First interruption"),
            .init(speaker: second, start: 30, text: "Later interruption"),
        ])
    }
}
