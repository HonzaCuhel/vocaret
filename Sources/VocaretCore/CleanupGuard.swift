import Foundation

/// Decides whether an LLM "cleanup" is actually a cleanup.
///
/// A small instruction-tuned model occasionally ignores the prompt and either
/// translates the text or answers it as if it were a question. Both are far
/// worse than leaving the raw transcript alone, and no amount of prompt wording
/// prevents them reliably — so the output is checked before it is used.
///
/// This is a lexical sanity check, not a semantic judge. Substantial deletion
/// is valid for repairs and repeated speech when the remaining text is grounded
/// in the input; the AI decides which details the speaker actually corrected.
public enum CleanupGuard {

    /// Fraction of the original words that must still be present.
    static let minimumRetention = 0.6
    /// How much longer the cleaned text may be (guards against the model
    /// answering, explaining, or padding).
    static let maximumGrowth = 1.6

    public static func isSafe(original: String, cleaned: String) -> Bool {
        let numbers = CleanupNumberEquivalence.check(original: original, cleaned: cleaned)
        guard numbers.isSupported else { return false }
        let originalWords = normalizedWords(numbers.original)
        let cleanedWords = normalizedWords(numbers.cleaned)
        guard !originalWords.isEmpty else { return !cleanedWords.isEmpty }
        guard !cleanedWords.isEmpty else { return false }

        if Double(cleanedWords.count) > Double(originalWords.count) * maximumGrowth + 1 {
            return false
        }

        var available: [String: Int] = [:]
        for word in cleanedWords { available[word, default: 0] += 1 }

        var retained = 0
        var retainedWords = Set<String>()
        for word in originalWords {
            if let count = available[word], count > 0 {
                available[word] = count - 1
                retained += 1
                retainedWords.insert(word)
            }
        }
        // Filler words are supposed to disappear, so short originals get a
        // little slack; long ones are held to the full ratio.
        let required = max(1, Int((Double(originalWords.count) * minimumRetention).rounded(.down)))
        let outputGrounding = Double(retained) / Double(cleanedWords.count)
        if retained >= required, outputGrounding >= 0.6 { return true }

        // Count distinct words here: a stutter repeated ten times is still one
        // idea. Do not let that exception accept an ordinary extractive summary:
        // the source must contain a repair cue, or adjacent repetition must
        // account for enough of the deletion to meet the ordinary retention gate.
        let distinctRetention = Double(retainedWords.count) / Double(Set(originalWords).count)
        guard outputGrounding >= 0.85, distinctRetention >= 0.25 else { return false }
        if hasExplicitRepairCue(in: originalWords) { return true }
        let repeatedCount = adjacentRepeatedWordCount(in: originalWords)
        guard repeatedCount > 0 else { return false }
        let requiredWithoutRepetition = max(1, Int((Double(originalWords.count - repeatedCount) * minimumRetention).rounded(.down)))
        return retained >= requiredWithoutRepetition
    }

    /// Lowercased, diacritic-stripped, punctuation-free words. "zitra" and
    /// "Zítra." must count as the same word — fixing those IS the job.
    static func normalizedWords(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // Multiword cues avoid treating ordinary negation, "actually", "also", or
    // "vlastně" alone as permission to discard most of a dictation. This remains
    // a lexical signal, not proof of which facts were repaired; the AI performs
    // every edit and still has to preserve unrelated details.
    private static let repairCues: [[String]] = [
        ["ne", "vlastne"], ["vlastne", "ne"], ["tedy", "ne"],
        ["chci", "rict"], ["myslel", "jsem"], ["opravuji", "na"],
        ["no", "actually"], ["actually", "make"], ["i", "mean"],
        ["i", "meant"], ["make", "that"],
        ["nein", "ich", "meine"], ["ich", "meinte"], ["besser", "gesagt"],
        ["doch", "lieber"],
        ["non", "pardon"], ["je", "veux", "dire"], ["je", "voulais", "dire"],
        ["no", "perdon"], ["quiero", "decir"], ["quise", "decir"],
        ["mejor", "dicho"], ["no", "mejor"],
    ]

    private static func hasExplicitRepairCue(in words: [String]) -> Bool {
        for cue in repairCues where words.count > cue.count + 1 {
            // Require speech both before and after the cue: an opening phrase
            // such as "I mean to send the report" is not a self-correction.
            for index in 1..<(words.count - cue.count) {
                if words[index..<(index + cue.count)].elementsEqual(cue) { return true }
            }
        }
        return false
    }

    private static func adjacentRepeatedWordCount(in words: [String]) -> Int {
        guard words.count >= 2 else { return 0 }
        var repeatedIndices = Set<Int>()
        // Only adjacent short words/phrases count. Recurring function words in
        // separate clauses must not relax protection of substantive details.
        for length in 1...min(4, words.count / 2) {
            for index in 0...(words.count - length * 2) {
                let duplicateStart = index + length
                if words[index..<duplicateStart].elementsEqual(words[duplicateStart..<(duplicateStart + length)]) {
                    repeatedIndices.formUnion(duplicateStart..<(duplicateStart + length))
                }
            }
        }
        return repeatedIndices.count
    }

}
