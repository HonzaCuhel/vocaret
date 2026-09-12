import Foundation

protocol OpenAIResponsesTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionOpenAIResponsesTransport: OpenAIResponsesTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIDictationCleanerError.invalidResponse
        }
        return (data, http)
    }
}

enum OpenAIDictationCleanerError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case incompleteResponse
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "OpenAI returned an invalid response."
        case .httpStatus(let status):
            "OpenAI request failed (HTTP \(status))."
        case .incompleteResponse:
            "OpenAI did not finish the cleanup."
        case .emptyOutput:
            "OpenAI returned no corrected text."
        }
    }
}

/// Fast cloud formatter for dictation. Failures, truncation, or suspicious
/// rewrites always return the original transcript instead of losing words.
struct OpenAIDictationCleaner: Sendable {
    static let shared = OpenAIDictationCleaner()
    static let model = "gpt-5-nano"

    private let transport: any OpenAIResponsesTransport
    private let endpoint: URL

    init(
        transport: any OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport(),
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) {
        self.transport = transport
        self.endpoint = endpoint
    }

    func cleanDictation(
        _ text: String,
        apiKey: String,
        vocabulary: [String]
    ) async -> String {
        await processDictation(text, apiKey: apiKey, vocabulary: vocabulary).text
    }

    func processDictation(
        _ text: String,
        apiKey: String,
        vocabulary: [String]
    ) async -> DictationCleanupResult {
        guard !text.isEmpty else { return DictationCleanupResult(text: text, failure: nil) }
        do {
            let request = try makeRequest(
                text: text,
                apiKey: apiKey,
                vocabulary: vocabulary
            )
            let (data, response) = try await transport.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw OpenAIDictationCleanerError.httpStatus(response.statusCode)
            }
            let cleaned = try Self.outputText(from: data)
            guard CleanupGuard.isSafe(original: text, cleaned: cleaned) else {
                Log.warn("Discarded OpenAI cleanup: output was not a correction of the input")
                return DictationCleanupResult(text: text, failure: .rejected)
            }
            return DictationCleanupResult(text: cleaned, failure: nil)
        } catch {
            Log.warn("OpenAI dictation cleanup skipped: \(error.localizedDescription)")
            let failure: DictationCleanupFailure = (error as? OpenAIDictationCleanerError) == .incompleteResponse
                || (error as? OpenAIDictationCleanerError) == .emptyOutput ? .incomplete : .unavailable
            return DictationCleanupResult(text: text, failure: failure)
        }
    }

    func makeRequest(text: String, apiKey: String, vocabulary: [String]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = DictationCleanup.timeout(for: text)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: Self.model,
            instructions: LLMPrompts.dictationSystem
                + LLMPrompts.vocabularyHint(terms: vocabulary),
            input: LLMPrompts.dictationUser(text),
            // Low effort improved repair handling and instruction-following in
            // multilingual checks while retaining the existing small model.
            reasoning: .init(effort: "low"),
            text: .init(verbosity: "low"),
            maxOutputTokens: 4_096,
            store: false
        ))
        return request
    }

    static func outputText(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard response.status == "completed" else {
            throw OpenAIDictationCleanerError.incompleteResponse
        }
        let text = response.output
            .flatMap(\.content)
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAIDictationCleanerError.emptyOutput }
        return text
    }
}

private extension OpenAIDictationCleaner {
    struct RequestBody: Encodable {
        let model: String
        let instructions: String
        let input: String
        let reasoning: Reasoning
        let text: TextOptions
        let maxOutputTokens: Int
        let store: Bool

        enum CodingKeys: String, CodingKey {
            case model, instructions, input, reasoning, text, store
            case maxOutputTokens = "max_output_tokens"
        }
    }

    struct Reasoning: Encodable { let effort: String }
    struct TextOptions: Encodable { let verbosity: String }

    struct ResponseBody: Decodable {
        let status: String
        let output: [OutputItem]
    }

    struct OutputItem: Decodable {
        let content: [Content]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            content = try container.decodeIfPresent([Content].self, forKey: .content) ?? []
        }

        private enum CodingKeys: String, CodingKey { case content }
    }

    struct Content: Decodable {
        let type: String
        let text: String?
    }
}
