import Foundation

enum MeetingNotesProvider: String, Sendable {
    case local
    case gpt5Nano = "gpt-5-nano"
}

enum MeetingNotesFailure: Error, Equatable, Sendable, LocalizedError {
    case emptyTranscript
    case missingAPIKey
    case unavailable
    case incompleteResponse
    case transcriptTooLarge
    case requestLimit
    case reductionLimit
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: "The meeting transcript is empty."
        case .missingAPIKey: "GPT-5 nano is selected, but the OpenAI API key is missing."
        case .unavailable: "The selected meeting-notes model is unavailable."
        case .incompleteResponse: "The selected model did not finish the meeting notes."
        case .transcriptTooLarge: "The transcript exceeds the meeting-notes processing limit."
        case .requestLimit: "Meeting notes reached the maximum number of model requests."
        case .reductionLimit: "The part notes could not be merged within the model's size limit."
        case .timedOut: "Meeting notes exceeded the processing time limit."
        case .cancelled: "Meeting-notes processing was cancelled."
        }
    }
}

struct MeetingNotesResult: Sendable {
    let markdown: String?
    let failure: MeetingNotesFailure?
    let completedParts: Int
    let totalParts: Int

    var isComplete: Bool { failure == nil && markdown != nil }
}

/// Request bounds apply to both providers. Byte counts conservatively budget
/// multilingual input; no transcript is truncated to make it fit.
struct MeetingNotesLimits: Sendable {
    var transcriptBytes = 12_000
    var mergeBytes = 18_000
    var maximumParts = 64
    var maximumRequests = 128
    var requestTimeout: TimeInterval = 120
    var overallTimeout: TimeInterval = 600
}

/// Provider selection is supplied by the caller's settings snapshot. A cloud
/// error never starts a local model or sends the transcript to another provider.
/// Keep the original transcript alongside this result, including on success.
struct MeetingNotesGenerator: Sendable {
    typealias LocalCompletion = @Sendable (String, String, Int, TimeInterval) async throws -> String

    static let shared = MeetingNotesGenerator()

    private let transport: any OpenAIResponsesTransport
    private let endpoint: URL
    private let localCompletion: LocalCompletion
    private let limits: MeetingNotesLimits

    init(
        transport: any OpenAIResponsesTransport = URLSessionOpenAIResponsesTransport(),
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        localCompletion: @escaping LocalCompletion = { system, user, maxTokens, timeout in
            try await LLMCleaner.shared.completeMeetingNotes(
                system: system, user: user, maxTokens: maxTokens, timeout: timeout
            )
        },
        limits: MeetingNotesLimits = MeetingNotesLimits()
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.localCompletion = localCompletion
        self.limits = limits
    }

    func generate(
        markdownTranscript: String,
        provider: MeetingNotesProvider,
        apiKey: String? = nil
    ) async -> MeetingNotesResult {
        let transcript = markdownTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        var partials: [String] = []
        var totalParts = 0
        var requestCount = 0
        do {
            guard !transcript.isEmpty else { throw MeetingNotesFailure.emptyTranscript }
            let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if provider == .gpt5Nano, key.isEmpty { throw MeetingNotesFailure.missingAPIKey }
            guard limits.transcriptBytes > 0, limits.mergeBytes > 0,
                  limits.maximumParts > 0, limits.maximumRequests > 0,
                  limits.requestTimeout.isFinite, limits.requestTimeout > 0,
                  limits.overallTimeout.isFinite, limits.overallTimeout > 0 else {
                throw MeetingNotesFailure.requestLimit
            }
            let deadline = ContinuousClock().now.advanced(by: .seconds(limits.overallTimeout))
            // Reject over-limit input before allocating chunks or making paid
            // requests. Repeated continuation labels count against the cap too.
            let (maximumBytes, overflow) = limits.transcriptBytes.multipliedReportingOverflow(by: limits.maximumParts)
            guard !overflow, transcript.utf8.count <= maximumBytes else {
                throw MeetingNotesFailure.transcriptTooLarge
            }
            let parts = try Self.transcriptParts(
                transcript, maxBytes: limits.transcriptBytes, maximumParts: limits.maximumParts
            )
            totalParts = parts.count
            if parts.count == 1 {
                let text = try await complete(
                    system: LLMPrompts.meetingSystem,
                    input: LLMPrompts.meetingUser(transcript: parts[0]),
                    provider: provider, apiKey: key, maxTokens: 8_192,
                    requestCount: &requestCount, deadline: deadline
                )
                return MeetingNotesResult(markdown: text, failure: nil, completedParts: 1, totalParts: 1)
            }

            for (index, part) in parts.enumerated() {
                let notes = try await complete(
                    system: LLMPrompts.meetingPartSystem,
                    input: LLMPrompts.meetingPartUser(part: index + 1, of: parts.count, transcript: part),
                    provider: provider, apiKey: key, maxTokens: 2_048,
                    requestCount: &requestCount, deadline: deadline
                )
                partials.append(notes)
            }

            // A single unbounded final merge used to overflow the local model.
            // Merge consecutive groups instead, reducing the count every round.
            // Retain the original complete part notes until the final merge has
            // succeeded, so any failure can return all already processed parts.
            var level = partials
            while level.count > 1 {
                let groups = try mergeGroups(level)
                guard groups.count < level.count else { throw MeetingNotesFailure.reductionLimit }
                var next: [String] = []
                for group in groups {
                    if group.count == 1 {
                        next.append(group[0])
                    } else {
                        let notes = try await complete(
                            system: LLMPrompts.meetingMergeSystem,
                            input: LLMPrompts.meetingMergeUser(partials: group),
                            provider: provider, apiKey: key, maxTokens: groups.count == 1 ? 4_096 : 2_048,
                            requestCount: &requestCount, deadline: deadline
                        )
                        next.append(notes)
                    }
                }
                level = next
            }
            return MeetingNotesResult(
                markdown: level.first, failure: nil, completedParts: partials.count, totalParts: totalParts
            )
        } catch {
            let failure = Self.failure(for: error)
            // Only the failure category is logged; never the transcript, API
            // response body, request or credential.
            Log.warn("Meeting notes incomplete: \(failure.localizedDescription)")
            let savedPartNotes = partials.isEmpty ? nil : partials.enumerated().map {
                "### Transcript part \($0.offset + 1)\n\n\($0.element)"
            }.joined(separator: "\n\n")
            return MeetingNotesResult(
                markdown: savedPartNotes, failure: failure,
                completedParts: partials.count, totalParts: totalParts
            )
        }
    }

    /// Split at turn boundaries where possible. An unusually long turn is
    /// split on Character boundaries and repeats its existing speaker/time
    /// label, preserving Unicode and attribution across every continuation.
    static func transcriptParts(_ transcript: String, maxBytes: Int, maximumParts: Int) throws -> [String] {
        guard maxBytes > 0, maximumParts > 0 else { throw MeetingNotesFailure.transcriptTooLarge }
        var result: [String] = []
        var current = ""

        func appendCurrent() throws {
            guard !current.isEmpty else { return }
            guard result.count < maximumParts else { throw MeetingNotesFailure.transcriptTooLarge }
            result.append(current)
            current = ""
        }

        func appendPiece(_ piece: String) throws {
            let combined = current.isEmpty ? piece : current + "\n\n" + piece
            if combined.utf8.count <= maxBytes {
                current = combined
            } else {
                try appendCurrent()
                current = piece
            }
        }

        for turn in transcript.components(separatedBy: "\n\n") {
            guard !turn.isEmpty else { continue }
            if turn.utf8.count <= maxBytes {
                try appendPiece(turn)
                continue
            }
            try appendCurrent()
            let header: String
            if let range = turn.range(of: #"^\*\*[^\n]+?:\*\*[ \t]*"#, options: .regularExpression) {
                header = String(turn[range])
            } else {
                header = ""
            }
            let availableBytes = maxBytes - header.utf8.count
            guard availableBytes > 0 else { throw MeetingNotesFailure.transcriptTooLarge }
            var fragment = ""
            var fragmentBytes = 0
            for character in turn.dropFirst(header.count) {
                let count = character.utf8.count
                guard count <= availableBytes else { throw MeetingNotesFailure.transcriptTooLarge }
                if fragmentBytes + count > availableBytes {
                    try appendPiece(header + fragment)
                    try appendCurrent()
                    fragment = ""
                    fragmentBytes = 0
                }
                fragment.append(character)
                fragmentBytes += count
            }
            if !fragment.isEmpty { try appendPiece(header + fragment) }
        }
        try appendCurrent()
        return result
    }

    private func mergeGroups(_ notes: [String]) throws -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        for note in notes {
            guard LLMPrompts.meetingMergeUser(partials: [note]).utf8.count <= limits.mergeBytes else {
                throw MeetingNotesFailure.reductionLimit
            }
            let candidate = current + [note]
            if !current.isEmpty, LLMPrompts.meetingMergeUser(partials: candidate).utf8.count > limits.mergeBytes {
                groups.append(current)
                current = [note]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func complete(
        system: String,
        input: String,
        provider: MeetingNotesProvider,
        apiKey: String,
        maxTokens: Int,
        requestCount: inout Int,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        try Task.checkCancellation()
        let remaining = ContinuousClock().now.duration(to: deadline).components
        let secondsLeft = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard secondsLeft > 0 else { throw MeetingNotesFailure.timedOut }
        guard requestCount < limits.maximumRequests else { throw MeetingNotesFailure.requestLimit }
        requestCount += 1
        let timeout = min(limits.requestTimeout, secondsLeft)
        let output: String
        switch provider {
        case .local:
            output = try await localCompletion(system, input, maxTokens, timeout)
        case .gpt5Nano:
            let request = try makeRequest(
                system: system, input: input, apiKey: apiKey, maxTokens: maxTokens, timeout: timeout
            )
            output = try await cloudCompletion(request, timeout: timeout)
        }
        try Task.checkCancellation()
        guard ContinuousClock().now < deadline else { throw MeetingNotesFailure.timedOut }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MeetingNotesFailure.incompleteResponse }
        return text
    }

    private func cloudCompletion(_ request: URLRequest, timeout: TimeInterval) async throws -> String {
        // URLRequest's timeout measures inactivity. A server emitting occasional
        // bytes must still respect the total deadline. Cancelling URLSession's
        // async data task also stops the in-flight request when the timer wins.
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let (data, response) = try await transport.data(for: request)
                guard (200..<300).contains(response.statusCode) else { throw MeetingNotesFailure.unavailable }
                return try OpenAIDictationCleaner.outputText(from: data)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MeetingNotesFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw MeetingNotesFailure.incompleteResponse }
            return result
        }
    }

    private func makeRequest(
        system: String, input: String, apiKey: String, maxTokens: Int, timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: MeetingNotesProvider.gpt5Nano.rawValue,
            instructions: system, input: input,
            reasoning: .init(effort: "low"), maxOutputTokens: maxTokens, store: false
        ))
        return request
    }

    private static func failure(for error: Error) -> MeetingNotesFailure {
        if let failure = error as? MeetingNotesFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .cancelled { return .cancelled }
            if error.code == .timedOut { return .timedOut }
        }
        if let error = error as? OpenAIDictationCleanerError,
           error == .incompleteResponse || error == .emptyOutput {
            return .incompleteResponse
        }
        return .unavailable
    }

    private struct RequestBody: Encodable {
        let model: String
        let instructions: String
        let input: String
        let reasoning: Reasoning
        let maxOutputTokens: Int
        let store: Bool

        enum CodingKeys: String, CodingKey {
            case model, instructions, input, reasoning, store
            case maxOutputTokens = "max_output_tokens"
        }

        struct Reasoning: Encodable { let effort: String }
    }
}
