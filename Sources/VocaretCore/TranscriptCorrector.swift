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
        if let fixed = learned[lowered] { return fixed + trailing }
        if let fixed = canonical[lowered] { return fixed + trailing }

        // Fuzzy: only for words long enough that a near miss is not a coincidence.
        if core.count >= 5 {
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
