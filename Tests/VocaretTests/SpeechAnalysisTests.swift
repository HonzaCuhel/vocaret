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

    func testOrdinalsAbbreviationsAndDecimalsDoNotEndSentences() {
        // Czech ordinals ("18. srpna", "9. patře"), abbreviations ("např.") and
        // version numbers must not be counted as sentence ends.
        let a = SpeechAnalysis.analyze(texts: ["Sejdeme se 18. srpna v 9. patře, verze 2.5, např. ta nová. Pak jdeme domů."])
        // Two sentences: 13 tokens + 3 tokens ("2.5" counts as two tokens).
        XCTAssertEqual(a.averageSentenceLength, 8.0, accuracy: 0.01)
        XCTAssertEqual(a.longestSentenceWords, 13)
    }

    func testSentencesStartingWithADigitOrQuoteStillSplit() {
        // "5 minut." and a quoted sentence must not be swallowed into the
        // previous one just because they do not start with a capital letter.
        let a = SpeechAnalysis.analyze(texts: ["Trvalo to dlouho. 5 minut. Pak nic."])
        XCTAssertEqual(a.averageSentenceLength, 2.33, accuracy: 0.01) // 3 + 2 + 2 tokens
        let b = SpeechAnalysis.analyze(texts: ["Řekl to. „Ano.“ Pak odešel."])
        XCTAssertEqual(b.longestSentenceWords, 2)
        // …and an ordinal still does not end a sentence.
        let c = SpeechAnalysis.analyze(texts: ["Bylo to fajn. 18. srpna jedeme."])
        XCTAssertEqual(c.averageSentenceLength, 3.0, accuracy: 0.01) // "Bylo to fajn" + "18 srpna jedeme"
    }

    func testVocabularyRichnessDoesNotFallWithCorpusSize() {
        // The same 50-word vocabulary dictated 2× vs 40× must score the same:
        // raw type/token ratio would halve and then collapse, punishing heavy users.
        let vocab = (1...50).map { "slovo\($0)" }
        let text = vocab.joined(separator: " ") + "."
        let small = SpeechAnalysis.analyze(texts: Array(repeating: text, count: 2))
        let large = SpeechAnalysis.analyze(texts: Array(repeating: text, count: 40))
        XCTAssertEqual(small.vocabularyRichness, large.vocabularyRichness, accuracy: 0.02)
        XCTAssertGreaterThan(large.vocabularyRichness, 0.4)
    }

    func testEmptyInput() {
        let a = SpeechAnalysis.analyze(texts: [])
        XCTAssertEqual(a.fillerCount, 0)
        XCTAssertEqual(a.averageSentenceLength, 0)
        XCTAssertEqual(a.vocabularyRichness, 0)
    }
}
