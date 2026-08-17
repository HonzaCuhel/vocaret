import XCTest
@testable import VocaretCore

final class VocabularyTests: XCTestCase {

    private func vocabulary(terms: [String] = [], learned: [String: String] = [:]) -> Vocabulary {
        let vocabulary = Vocabulary(persistence: nil)
        vocabulary.terms = terms
        for (wrong, right) in learned {
            vocabulary.forceLearn(wrong: wrong, right: right)
        }
        return vocabulary
    }

    // MARK: - Canonical spelling of known terms

    func testFixesCasingOfKnownTerm() {
        let v = vocabulary(terms: ["Whisper", "GitHub"])
        XCTAssertEqual(TranscriptCorrector.apply("Ten whisper zase nefunguje.", vocabulary: v),
                       "Ten Whisper zase nefunguje.")
        XCTAssertEqual(TranscriptCorrector.apply("Pushni to na github.", vocabulary: v),
                       "Pushni to na GitHub.")
    }

    func testFixesNearMissSpelling() {
        let v = vocabulary(terms: ["WhisperKit", "Vocaret"])
        // One-character errors of the kind Whisper actually makes.
        XCTAssertEqual(TranscriptCorrector.apply("Použij WisperKit.", vocabulary: v), "Použij WhisperKit.")
        XCTAssertEqual(TranscriptCorrector.apply("Spusť vocaretu.", vocabulary: v), "Spusť Vocaret.")
    }

    func testDoesNotTouchUnrelatedWords() {
        let v = vocabulary(terms: ["Whisper"])
        let text = "Dneska prší a půjdu ven."
        XCTAssertEqual(TranscriptCorrector.apply(text, vocabulary: v), text)
    }

    func testShortWordsAreNotFuzzyMatched() {
        // "kde" must not become "Codex" — fuzzy matching on short words is unsafe.
        let v = vocabulary(terms: ["Codex"])
        XCTAssertEqual(TranscriptCorrector.apply("Kde to je?", vocabulary: v), "Kde to je?")
    }

    func testPreservesPunctuationAndSurroundings() {
        let v = vocabulary(terms: ["Whisper"])
        XCTAssertEqual(TranscriptCorrector.apply("Funguje whisper? Ano, whisper!", vocabulary: v),
                       "Funguje Whisper? Ano, Whisper!")
        XCTAssertEqual(TranscriptCorrector.apply("(whisper)", vocabulary: v), "(Whisper)")
    }

    func testEmptyVocabularyIsIdentity() {
        let v = vocabulary()
        let text = "Nic se tu nemá měnit."
        XCTAssertEqual(TranscriptCorrector.apply(text, vocabulary: v), text)
    }

    // MARK: - Learned corrections

    func testLearnedCorrectionIsApplied() {
        let v = vocabulary(learned: ["ilokální": "lokální"])
        XCTAssertEqual(TranscriptCorrector.apply("Nějaký menší ilokální model.", vocabulary: v),
                       "Nějaký menší lokální model.")
    }

    func testLearningNeedsRepetitionBeforeItApplies() {
        let v = Vocabulary(persistence: nil)
        v.learn(from: "ten whisper je fajn", to: "ten Whisper je fajn")
        // Seen once: recorded but not yet trusted.
        XCTAssertEqual(TranscriptCorrector.apply("ten whisper", vocabulary: v), "ten whisper")

        v.learn(from: "zase whisper spadl", to: "zase Whisper spadl")
        // Seen twice: now applied automatically.
        XCTAssertEqual(TranscriptCorrector.apply("ten whisper", vocabulary: v), "ten Whisper")
    }

    func testLearningIgnoresRewritesThatChangeWordCount() {
        let v = Vocabulary(persistence: nil)
        // The LLM removed a filler word — positions no longer line up, so
        // nothing may be learned from this pair.
        v.learn(from: "no takže ehm zítra", to: "Zítra")
        v.learn(from: "no takže ehm zítra", to: "Zítra")
        XCTAssertTrue(v.learnedCorrections.isEmpty)
    }

    func testLearningIgnoresPurePunctuationAndVeryDifferentWords() {
        let v = Vocabulary(persistence: nil)
        for _ in 0..<3 {
            v.learn(from: "pes běžel domů", to: "kočka běžel domů") // unrelated substitution
        }
        XCTAssertNil(v.learnedCorrections["pes"])
    }

    func testLearnedCorrectionsRoundTripThroughDisk() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Vocabulary(persistence: directory)
        first.terms = ["Vocaret", "llama.cpp"]
        first.forceLearn(wrong: "ilokální", right: "lokální")
        first.save()

        let second = Vocabulary(persistence: directory)
        XCTAssertEqual(second.terms, ["Vocaret", "llama.cpp"])
        XCTAssertEqual(second.learnedCorrections["ilokální"], "lokální")
    }

    func testVocabularyFileIgnoresCommentsAndBlankLines() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "# my words\n\nWhisper\n  GitHub  \n\n# done\n"
            .write(to: directory.appendingPathComponent("vocabulary.txt"), atomically: true, encoding: .utf8)

        let v = Vocabulary(persistence: directory)
        XCTAssertEqual(v.terms, ["Whisper", "GitHub"])
    }
}
