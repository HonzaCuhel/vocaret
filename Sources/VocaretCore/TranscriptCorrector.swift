import AppKit
import Foundation

/// Applies the user's vocabulary to a transcript: exact-but-miscased terms are
/// re-cased, near misses are snapped to the canonical spelling, and learned
/// corrections are substituted. Pure and fast — runs on every dictation whether
/// or not the AI cleanup is enabled.
public enum TranscriptCorrector {

    /// `language` is the language the utterance was recognised as. Passing it
    /// makes the "is this already a real word?" guard much sharper: inside a
    /// Czech sentence, "Slag" is not a Czech word, so it can be snapped to the
    /// user's "Slack" — while in an English sentence "slag" is left alone.
    public static func apply(_ text: String, vocabulary: Vocabulary, language: String? = nil) -> String {
        let terms = vocabulary.terms
        let learned = vocabulary.learnedCorrections
        guard !terms.isEmpty || !learned.isEmpty else { return text }

        var canonical: [String: String] = [:]
        for term in terms { canonical[term.lowercased()] = term }

        let text = rejoinSplitTerms(text, canonical: canonical)

        var result = ""
        result.reserveCapacity(text.count)
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            result += correctWord(current, canonical: canonical, learned: learned, terms: terms, language: language)
            current = ""
        }

        // Split on anything that is not part of a word, keeping separators.
        for character in text {
            if character.isLetter || character.isNumber || character == "." && !current.isEmpty {
                current.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    private static func correctWord(
        _ word: String,
        canonical: [String: String],
        learned: [String: String],
        terms: [String],
        language: String?
    ) -> String {
        // Words like "llama.cpp" pick up a trailing sentence period; correct the
        // core and hand the punctuation back untouched.
        var core = word
        var trailing = ""
        while let last = core.last, last == "." {
            core.removeLast()
            trailing = "." + trailing
        }
        guard !core.isEmpty else { return word }

        let lowered = core.lowercased()
        // The user's explicit spelling always wins over anything learned.
        if let fixed = canonical[lowered] { return fixed + trailing }
        if let fixed = learned[lowered] { return fixed + trailing }

        // Fuzzy: only for words long enough that a near miss is not a coincidence,
        // and never for words that are themselves valid ("codes" must not become
        // "Codex", "clause" must not become "Claude"). When the utterance's
        // language is known the check is that much sharper, so four-letter
        // misses like "Slag" for "Slack" can be caught too.
        let minimumLength = language == nil ? 5 : 4
        if core.count >= minimumLength, !isRealWord(core, language: language) {
            let budget = core.count >= 8 ? 2 : 1
            // Czech devoices consonants at the end of a word, so a recogniser
            // writing Czech hears "Slack" as "Slag". Comparing the devoiced
            // forms turns that into an ordinary near miss.
            let folded = Self.foldFinalVoicing(lowered)
            var best: (term: String, distance: Int)?
            for term in terms where abs(term.count - core.count) <= budget {
                let loweredTerm = term.lowercased()
                let distance = min(
                    editDistance(lowered, loweredTerm),
                    editDistance(folded, Self.foldFinalVoicing(loweredTerm))
                )
                if distance <= budget, distance < (best?.distance ?? Int.max) {
                    best = (term, distance)
                }
            }
            if let best { return best.term + trailing }
        }
        return word
    }

    /// Speech recognisers split multi-word product names inside foreign
    /// speech — Parakeet writes "git hub" and "whisper kit" in a Czech
    /// sentence. Two adjacent words are joined only when the join is EXACTLY a
    /// vocabulary term (no fuzzy matching), so ordinary Czech words that happen
    /// to sit next to each other are never welded together.
    static func rejoinSplitTerms(_ text: String, canonical: [String: String]) -> String {
        guard !canonical.isEmpty else { return text }
        // Split into words and the separators between them, keeping both.
        var pieces: [String] = []
        var isWord: [Bool] = []
        var current = ""
        var currentIsWord: Bool?
        for character in text {
            let wordish = character.isLetter || character.isNumber
            if currentIsWord == nil || wordish == currentIsWord {
                current.append(character)
            } else {
                pieces.append(current); isWord.append(currentIsWord!)
                current = String(character)
            }
            currentIsWord = wordish
        }
        if !current.isEmpty, let last = currentIsWord { pieces.append(current); isWord.append(last) }

        var result = ""
        var index = 0
        while index < pieces.count {
            // word, single space, word → try the join
            if isWord[index], index + 2 < pieces.count, pieces[index + 1] == " ", isWord[index + 2],
               let joined = canonical[(pieces[index] + pieces[index + 2]).lowercased()] {
                result += joined
                index += 3
                continue
            }
            result += pieces[index]
            index += 1
        }
        return result
    }

    /// True if the system spell checker knows the word — in `language` when the
    /// utterance's language is known, otherwise in any of the app's languages
    /// (Czech + English + auto-detect set). Cached per process.
    static func isRealWord(_ word: String, language: String? = nil) -> Bool {
        let key = (language ?? "*") + ":" + word.lowercased()
        realWordLock.lock()
        if let cached = realWordCache[key] { realWordLock.unlock(); return cached }
        realWordLock.unlock()
        var languages: [String]
        if let language {
            languages = [language]
        } else {
            languages = Array(Set(["en", "cs"] + SettingsStore.shared.autoLanguages))
        }
        let checker = NSSpellChecker.shared
        var real = false
        for language in languages {
            let range = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if range.location == NSNotFound { real = true; break }
        }
        realWordLock.lock(); realWordCache[key] = real; realWordLock.unlock()
        return real
    }
    private static var realWordCache: [String: Bool] = [:]
    private static let realWordLock = NSLock()

    /// The final consonant folded onto its voiceless pair — the way Czech
    /// actually pronounces the end of a word, where "Slack" and "Slag" are
    /// indistinguishable. Only the last letter is touched.
    static func foldFinalVoicing(_ word: String) -> String {
        let pairs: [Character: Character] = ["g": "k", "d": "t", "b": "p", "z": "s", "ž": "š", "v": "f"]
        guard let last = word.last, let voiceless = pairs[last] else { return word }
        return String(word.dropLast()) + String(voiceless)
    }

    /// Levenshtein distance, iterative single-row.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let first = Array(a), second = Array(b)
        if first.isEmpty { return second.count }
        if second.isEmpty { return first.count }
        var previous = Array(0...second.count)
        var current = [Int](repeating: 0, count: second.count + 1)
        for i in 1...first.count {
            current[0] = i
            for j in 1...second.count {
                let cost = first[i - 1] == second[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[second.count]
    }
}
