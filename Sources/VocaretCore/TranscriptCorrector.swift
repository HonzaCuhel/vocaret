import AppKit
import Foundation

/// Applies the user's vocabulary to a transcript: exact-but-miscased terms are
/// re-cased, near misses are snapped to the canonical spelling, and learned
/// corrections are substituted. Pure and fast — runs on every dictation whether
/// or not the AI cleanup is enabled.
public enum TranscriptCorrector {

    public static func apply(_ text: String, vocabulary: Vocabulary) -> String {
        let terms = vocabulary.terms
        let learned = vocabulary.learnedCorrections
        guard !terms.isEmpty || !learned.isEmpty else { return text }

        var canonical: [String: String] = [:]
        for term in terms { canonical[term.lowercased()] = term }

        var result = ""
        result.reserveCapacity(text.count)
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            result += correctWord(current, canonical: canonical, learned: learned, terms: terms)
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
        terms: [String]
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
        // "Codex", "clause" must not become "Claude").
        if core.count >= 5, !isRealWord(core) {
            let budget = core.count >= 8 ? 2 : 1
            var best: (term: String, distance: Int)?
            for term in terms where abs(term.count - core.count) <= budget {
                let distance = editDistance(lowered, term.lowercased())
                if distance <= budget, distance < (best?.distance ?? Int.max) {
                    best = (term, distance)
                }
            }
            if let best { return best.term + trailing }
        }
        return word
    }

    /// True if the system spell checker knows the word in any of the app's
    /// languages (Czech + English + auto-detect set). Cached per process.
    static func isRealWord(_ word: String) -> Bool {
        let key = word.lowercased()
        realWordLock.lock()
        if let cached = realWordCache[key] { realWordLock.unlock(); return cached }
        realWordLock.unlock()
        var languages = ["en", "cs"] + SettingsStore.shared.autoLanguages
        languages = Array(Set(languages))
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
