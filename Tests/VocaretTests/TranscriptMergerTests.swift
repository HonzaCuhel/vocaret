import XCTest
@testable import VocaretCore

final class TranscriptMergerTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ text: String) -> SpokenSegment {
        SpokenSegment(start: start, end: end, text: text)
    }

    func testInterleavesChronologically() {
        let mine = [seg(0, 2, "Hello"), seg(10, 12, "Sure, works for me")]
        let theirs = [seg(3, 8, "Hi, can we move the meeting?")]

        let turns = TranscriptMerger.merge(mine: mine, theirs: theirs)

        XCTAssertEqual(turns.map(\.speaker), [.me, .them, .me])
        XCTAssertEqual(turns.map(\.text), ["Hello", "Hi, can we move the meeting?", "Sure, works for me"])
    }

    func testCoalescesSameSpeakerWithinGap() {
        let mine = [seg(0, 2, "First part."), seg(3, 5, "Second part.")]

        let turns = TranscriptMerger.merge(mine: mine, theirs: [], coalesceGap: 2.0)

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "First part. Second part.")
        XCTAssertEqual(turns[0].start, 0)
    }

    func testDoesNotCoalesceSameSpeakerBeyondGap() {
        let mine = [seg(0, 2, "First."), seg(10, 12, "Much later.")]

        let turns = TranscriptMerger.merge(mine: mine, theirs: [], coalesceGap: 2.0)

        XCTAssertEqual(turns.count, 2)
    }

    func testDoesNotCoalesceAcrossSpeakerChange() {
        let mine = [seg(0, 2, "Question?"), seg(4.5, 6, "Thanks.")]
        let theirs = [seg(2.2, 4, "Answer.")]

        let turns = TranscriptMerger.merge(mine: mine, theirs: theirs, coalesceGap: 2.0)

        XCTAssertEqual(turns.map(\.speaker), [.me, .them, .me])
    }

    func testDropsEmptyAndWhitespaceSegmentsAndTrims() {
        let mine = [seg(0, 1, "  Hello  "), seg(2, 3, "   "), seg(9, 10, "")]

        let turns = TranscriptMerger.merge(mine: mine, theirs: [])

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "Hello")
    }

    func testEmptyTracksProduceEmptyResult() {
        XCTAssertTrue(TranscriptMerger.merge(mine: [], theirs: []).isEmpty)

        let onlyTheirs = TranscriptMerger.merge(mine: [], theirs: [seg(1, 2, "Solo")])
        XCTAssertEqual(onlyTheirs.count, 1)
        XCTAssertEqual(onlyTheirs[0].speaker, .them)
    }

    func testMarkdownFormat() {
        let turns = [
            MergedTurn(speaker: .me, start: 0, text: "Ahoj, slyšíme se?"),
            MergedTurn(speaker: .them, start: 192, text: "Yes, loud and clear."),
        ]

        let markdown = TranscriptMerger.markdown(turns: turns)

        XCTAssertEqual(markdown, """
        **Me [00:00:00]:** Ahoj, slyšíme se?

        **Them [00:03:12]:** Yes, loud and clear.
        """)
    }

    func testTimestampFormattingPastOneHour() {
        XCTAssertEqual(TranscriptMerger.timestamp(3723), "01:02:03")
        XCTAssertEqual(TranscriptMerger.timestamp(59.9), "00:00:59")
        XCTAssertEqual(TranscriptMerger.timestamp(0), "00:00:00")
    }
}
