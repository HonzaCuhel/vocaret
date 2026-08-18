import XCTest
@testable import VocaretCore

final class SpeechAnalysisTests: XCTestCase {
    func testFillerWordsAreCountedInCzechAndEnglish() {
        let texts = ["No takže ehm zítra máme jako schůzku, vlastně v devět.", "So um I think like we should, you know, ship it."]
        let a = SpeechAnalysis.analyze(texts: texts)
        XCTAssertEqual(a.fillerCount, 7) // takže ehm jako vlastně | um like "you know"
        XCTAssertGreaterThan(a.fillerRate, 0)
        XCTAssertEqual(a.topFillers.first?.word, "ehm") // all tied at 1 → alphabetical
    }

    func testAverageSentenceLength() {
        let a = SpeechAnalysis.analyze(texts: ["Jedna dvě tři. Čtyři pět. Šest sedm osm devět."])
        XCTAssertEqual(a.averageSentenceLength, 3.0, accuracy: 0.01)
    }

    func testVocabularyRichnessIsTypeTokenRatio() {
        let a = SpeechAnalysis.analyze(texts: ["a a a b"])
        XCTAssertEqual(a.vocabularyRichness, 0.5, accuracy: 0.001)
    }

    func testEmptyInput() {
        let a = SpeechAnalysis.analyze(texts: [])
        XCTAssertEqual(a.fillerCount, 0)
        XCTAssertEqual(a.averageSentenceLength, 0)
        XCTAssertEqual(a.vocabularyRichness, 0)
    }
}
