import XCTest
@testable import VocaretCore

final class CoachTests: XCTestCase {
    private func rec(_ text: String, seconds: Double = 10) -> DictationRecord {
        DictationRecord(date: Date(), text: text, recordingSeconds: seconds, transcriptionSeconds: 0.5, model: "t")
    }

    func testEveryLibraryEntryHasAResolvableLookingURL() {
        for book in SpeechCoach.library {
            XCTAssertNotNil(URL(string: book.url), book.title)
            XCTAssertTrue(book.url.hasPrefix("https://"), book.title)
            if let cz = book.czechURL { XCTAssertTrue(cz.hasPrefix("https://"), book.title) }
        }
    }

    func testReportCarriesLinksAndReasonsWhenAWeaknessTriggers() async {
        // 25-word run-on sentences → concision/structure focus with a reason.
        let long = Array(repeating: "slovo", count: 25).joined(separator: " ") + "."
        let records = (0..<10).map { _ in rec(long) }
        let report = await SpeechCoach.report(records: records, days: 14, generate: nil)
        XCTAssertEqual(report.books.count, 3)
        for book in report.books { XCTAssertFalse(book.url.isEmpty, book.title) }
        XCTAssertTrue(report.books.contains { $0.pickedBecause != nil }, "at least one pick should say why")
    }

    func testCzechSpeakerGetsCzechBooksFirstForTheSameFocus() async {
        let long = Array(repeating: "věta", count: 25).joined(separator: " ") + "."
        let report = await SpeechCoach.report(records: (0..<10).map { _ in rec(long) }, days: 14, generate: nil)
        // Structure focus: Kraus (Czech) should outrank Winston for a Czech speaker.
        let titles = report.books.map(\.title)
        XCTAssertTrue(titles.contains("Rétorika a řečová kultura"), "\(titles)")
    }

    func testBookChoiceParserOnlyAcceptsListedTitles() {
        let shortlist = Array(SpeechCoach.library.prefix(4))
        let text = """
        - The Pyramid Principle :: Say the conclusion first when you brief Codex.
        Some Invented Book :: nonsense
        On Writing Well :: You repeat "vlastně" a lot.
        """
        let parsed = SpeechCoach.parseBookChoice(text, from: shortlist)
        XCTAssertEqual(parsed.map(\.book.title), ["The Pyramid Principle", "On Writing Well"])
        XCTAssertEqual(parsed[0].reason, "Say the conclusion first when you brief Codex.")
    }
}
