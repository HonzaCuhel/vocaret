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

    func testSentenceInitialCapitalizationIsNotLearned() {
        // The LLM capitalises the first word of every sentence. That must not
        // become a permanent "a" → "A" rule applied mid-sentence.
        let v = Vocabulary(persistence: nil)
        for _ in 0..<3 {
            v.learn(from: "a pak jsme šli domů. the end", to: "A pak jsme šli domů. The end")
        }
        XCTAssertNil(v.learnedCorrections["a"])
        XCTAssertNil(v.learnedCorrections["the"])
        // …but a proper-noun casing fix in the middle of a sentence IS learned.
        for _ in 0..<2 { v.learn(from: "ten whisper zase spadl", to: "ten Whisper zase spadl") }
        XCTAssertEqual(v.learnedCorrections["whisper"], "Whisper")
    }

    func testAWordTheLLMLeavesAloneElsewhereIsNotLearnedAsWrong() {
        // "byli" → "byly" is grammatical agreement, not a spelling error: the same
        // word survives cleanup untouched in other sentences, so it is vetoed.
        let v = Vocabulary(persistence: nil)
        v.learn(from: "oni byli doma", to: "oni byly doma")
        v.learn(from: "oni byli doma", to: "oni byly doma")
        v.learn(from: "muži byli venku", to: "muži byli venku") // untouched → real word
        XCTAssertNil(v.learnedCorrections["byli"])
    }

    func testExplicitVocabularyBeatsLearnedCorrection() {
        let v = vocabulary(terms: ["WhisperKit"], learned: ["whisperkit": "Whisperkit"])
        XCTAssertEqual(TranscriptCorrector.apply("Použij whisperkit.", vocabulary: v), "Použij WhisperKit.")
    }

    func testRealWordsAreNotFuzzySnappedToTerms() {
        // "codes" is one edit from "Codex", "clause" one from "Claude" — both are
        // real English words and must survive.
        let v = vocabulary(terms: ["Codex", "Claude"])
        XCTAssertEqual(TranscriptCorrector.apply("The codes have a clause.", vocabulary: v), "The codes have a clause.")
        // …while a genuine non-word near miss still snaps. ("kodexu" would NOT:
        // it is a real Czech word — that case is the LLM's job via the vocabulary hint.)
        XCTAssertEqual(TranscriptCorrector.apply("Zeptej se Codexx.", vocabulary: v), "Zeptej se Codex.")
    }

    // MARK: - Terms the recogniser split in two

    func testRejoinsSplitTerms() {
        // Parakeet in particular splits English product names inside Czech
        // speech: "git hub", "whisper kit". The user's own vocabulary says
        // what the word should be.
        let v = vocabulary(terms: ["GitHub", "WhisperKit"])
        XCTAssertEqual(TranscriptCorrector.apply("Pushni to na git hub.", vocabulary: v),
                       "Pushni to na GitHub.")
        XCTAssertEqual(TranscriptCorrector.apply("Použij whisper kit dneska.", vocabulary: v),
                       "Použij WhisperKit dneska.")
    }

    func testDoesNotJoinWordsThatOnlyLookAdjacent() {
        let v = vocabulary(terms: ["GitHub"])
        // Not adjacent, and the join is not the term.
        XCTAssertEqual(TranscriptCorrector.apply("git a hub", vocabulary: v), "git a hub")
        // A near miss is NOT enough to join two ordinary Czech words.
        let codex = vocabulary(terms: ["Codex"])
        XCTAssertEqual(TranscriptCorrector.apply("co dexu tam je", vocabulary: codex), "co dexu tam je")
    }

    func testRejoiningKeepsSurroundingPunctuation() {
        let v = vocabulary(terms: ["GitHub"])
        XCTAssertEqual(TranscriptCorrector.apply("Je to na git hub, že?", vocabulary: v),
                       "Je to na GitHub, že?")
    }

    // MARK: - Knowing the language of the sentence

    func testEnglishTermMisheardInsideCzechIsSnappedToTheVocabulary() {
        // Whisper writes "Slag" for "Slack" in Czech speech. "slag" IS a real
        // English word, so the general guard protects it — but this sentence is
        // Czech, where it is not a word at all, so the user's term wins.
        let v = vocabulary(terms: ["Slack"])
        XCTAssertEqual(TranscriptCorrector.apply("Napiš to na Slag.", vocabulary: v, language: "cs"),
                       "Napiš to na Slack.")
    }

    func testTheSameWordIsLeftAloneInAnEnglishSentence() {
        let v = vocabulary(terms: ["Slack"])
        XCTAssertEqual(TranscriptCorrector.apply("We dumped it on the slag heap.", vocabulary: v, language: "en"),
                       "We dumped it on the slag heap.")
    }

    func testRealCzechWordsSurviveEvenWhenNearATerm() {
        // "kodex" is a real Czech word one edit from "Codex" — it must survive
        // a Czech dictation.
        let v = vocabulary(terms: ["Codex"])
        XCTAssertEqual(TranscriptCorrector.apply("Podle kodexu to nejde.", vocabulary: v, language: "cs"),
                       "Podle kodexu to nejde.")
        // …while a non-word still snaps.
        XCTAssertEqual(TranscriptCorrector.apply("Zeptej se Codexx.", vocabulary: v, language: "cs"),
                       "Zeptej se Codex.")
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
