import Foundation

/// Decides whether an LLM "cleanup" is actually a cleanup.
///
/// A small instruction-tuned model occasionally ignores the prompt and either
/// translates the text or answers it as if it were a question. Both are far
/// worse than leaving the raw transcript alone, and no amount of prompt wording
/// prevents them reliably — so the output is checked before it is used.
///
/// The test is deliberately crude and language-agnostic: a genuine correction
/// keeps most of the words you actually said.
public enum CleanupGuard {

    /// Fraction of the original words that must still be present.
    static let minimumRetention = 0.6
    /// How much longer the cleaned text may be (guards against the model
    /// answering, explaining, or padding).
    static let maximumGrowth = 1.6

    public static func isSafe(original: String, cleaned: String) -> Bool {
        let originalWords = normalizedWords(original)
        let cleanedWords = normalizedWords(cleaned)
        guard !originalWords.isEmpty else { return !cleanedWords.isEmpty }
        guard !cleanedWords.isEmpty else { return false }

        if Double(cleanedWords.count) > Double(originalWords.count) * maximumGrowth + 1 {
            return false
        }

        var available: [String: Int] = [:]
        for word in cleanedWords { available[word, default: 0] += 1 }

        var retained = 0
        for word in originalWords {
            if let count = available[word], count > 0 {
                available[word] = count - 1
                retained += 1
            }
        }
        // Filler words are supposed to disappear, so short originals get a
        // little slack; long ones are held to the full ratio.
        let required = max(1, Int((Double(originalWords.count) * minimumRetention).rounded(.down)))
        return retained >= required
    }

    /// Lowercased, diacritic-stripped, punctuation-free words. "zitra" and
    /// "Zítra." must count as the same word — fixing those IS the job.
    static func normalizedWords(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
