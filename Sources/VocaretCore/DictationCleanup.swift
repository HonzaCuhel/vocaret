import Foundation

enum DictationCleanupFailure: Equatable, Sendable {
    case unavailable
    case incomplete
    case rejected
}

struct DictationCleanupResult: Equatable, Sendable {
    let text: String
    let failure: DictationCleanupFailure?

    var isFormatted: Bool { failure == nil }
}

enum DictationCleanup {
    static func warmUp(model: String) {
        if model == "local" { LLMCleaner.shared.warmUp() }
    }

    /// Give longer dictations time to generate their complete formatted text,
    /// while keeping a bounded wait if a provider stops responding.
    static func timeout(for text: String) -> TimeInterval {
        min(45, max(12, 10 + Double(text.utf8.count) / 80))
    }

    static func clean(_ text: String, model: String) async -> String {
        await process(text, model: model).text
    }

    static func process(_ text: String, model: String) async -> DictationCleanupResult {
        guard model == "gpt-5-nano" else {
            return await LLMCleaner.shared.processDictation(text)
        }
        do {
            guard let key = try await AsyncAPIKeyAccess.shared.load(.openAI) else {
                Log.warn("OpenAI dictation cleanup skipped: API key is missing")
                return DictationCleanupResult(text: text, failure: .unavailable)
            }
            return await OpenAIDictationCleaner.shared.processDictation(
                text, apiKey: key, vocabulary: Vocabulary.shared.terms
            )
        } catch {
            Log.warn("OpenAI dictation cleanup skipped: \(error.localizedDescription)")
            return DictationCleanupResult(text: text, failure: .unavailable)
        }
    }
}
