import Foundation

enum SonioxRegion: String, CaseIterable, Sendable {
    case us
    case eu

    var webSocketURL: URL {
        switch self {
        case .us:
            URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
        case .eu:
            URL(string: "wss://stt-rt.eu.soniox.com/transcribe-websocket")!
        }
    }

    var restAPIBaseURL: URL {
        switch self {
        case .us:
            URL(string: "https://api.soniox.com")!
        case .eu:
            URL(string: "https://api.eu.soniox.com")!
        }
    }
}

struct SonioxConfiguration: Sendable {
    let apiKey: String
    let region: SonioxRegion
    let languageHints: [String]
    let terms: [String]

    func data() throws -> Data {
        try JSONEncoder().encode(WireConfiguration(
            apiKey: apiKey,
            model: "stt-rt-v5",
            audioFormat: "pcm_f32le",
            sampleRate: 16_000,
            numChannels: 1,
            languageHints: languageHints,
            languageHintsStrict: !languageHints.isEmpty,
            enableLanguageIdentification: true,
            context: Context(terms: terms)
        ))
    }

    private struct WireConfiguration: Encodable {
        let apiKey: String
        let model: String
        let audioFormat: String
        let sampleRate: Int
        let numChannels: Int
        let languageHints: [String]
        let languageHintsStrict: Bool
        let enableLanguageIdentification: Bool
        let context: Context

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case model
            case audioFormat = "audio_format"
            case sampleRate = "sample_rate"
            case numChannels = "num_channels"
            case languageHints = "language_hints"
            case languageHintsStrict = "language_hints_strict"
            case enableLanguageIdentification = "enable_language_identification"
            case context
        }
    }

    private struct Context: Encodable {
        let terms: [String]
    }
}

struct SonioxToken: Decodable, Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let language: String?

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
        case language
    }
}

struct SonioxResponse: Decodable, Equatable, Sendable {
    let tokens: [SonioxToken]
    let finished: Bool
    let errorCode: Int?
    let errorType: String?
    let errorMessage: String?
    let requestID: String?

    private enum CodingKeys: String, CodingKey {
        case tokens
        case finished
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
        case requestID = "request_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decodeIfPresent([SonioxToken].self, forKey: .tokens) ?? []
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        errorCode = try container.decodeIfPresent(Int.self, forKey: .errorCode)
        errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
    }
}

struct SonioxTranscriptUpdate: Equatable, Sendable {
    let visibleText: String
    let finalText: String
    let detectedLanguage: String?
    let didFinalize: Bool
}

struct SonioxTranscriptAccumulator: Sendable {
    private var committedText = ""
    private var tentativeText = ""
    private var finalLanguageWeights: [String: Int] = [:]

    var detectedLanguage: String? {
        finalLanguageWeights.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.first?.key
    }

    mutating func consume(_ data: Data) throws -> SonioxTranscriptUpdate {
        let response = try JSONDecoder().decode(SonioxResponse.self, from: data)
        return consume(response)
    }

    mutating func consume(_ response: SonioxResponse) -> SonioxTranscriptUpdate {
        var nextTentativeText = ""
        var didFinalize = false

        for token in response.tokens {
            switch token.text {
            case "<fin>":
                didFinalize = true
            case "<end>":
                continue
            default:
                if token.isFinal {
                    committedText += token.text
                    if let language = token.language?.lowercased(), !language.isEmpty {
                        finalLanguageWeights[language, default: 0] += token.text.utf8.count
                    }
                } else {
                    nextTentativeText += token.text
                }
            }
        }

        tentativeText = nextTentativeText
        return SonioxTranscriptUpdate(
            visibleText: committedText + tentativeText,
            finalText: committedText.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: detectedLanguage,
            didFinalize: didFinalize
        )
    }
}
