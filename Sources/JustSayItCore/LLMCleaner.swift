import Foundation

/// Thread-safe holder so the spawned llama-server can be terminated
/// synchronously from `applicationWillTerminate` (outside the actor).
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var pid: pid_t?

    /// Track a server we spawned. Its PID is persisted so a later app launch
    /// can reap it if this one crashes or is force-quit.
    func set(_ newProcess: Process, pidFile: URL) {
        lock.lock()
        defer { lock.unlock() }
        process = newProcess
        pid = newProcess.processIdentifier
        try? String(newProcess.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    /// Track a server started by a previous app instance (found via pidfile +
    /// healthy port) so the idle timer can still shut it down.
    func adopt(pid adoptedPid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        process = nil
        pid = adoptedPid
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if let process, process.isRunning {
            process.terminate()
        } else if let pid, kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
        }
        process = nil
        pid = nil
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let process { return process.isRunning }
        if let pid { return kill(pid, 0) == 0 }
        return false
    }
}

/// Cleans dictation and structures meeting transcripts with a local LLM.
///
/// RAM strategy: `llama-server` is spawned only when needed and killed after
/// 120 s idle, so the ~2.5 GB model occupies memory only around actual work.
/// Every public method degrades gracefully — on any failure the original
/// text is returned unchanged and the pipeline continues.
public actor LLMCleaner {
    public static let shared = LLMCleaner()

    nonisolated let processBox = ProcessBox()
    private var idleShutdownTask: Task<Void, Never>?

    private let idleTimeout: TimeInterval = 120
    private let startupTimeout: TimeInterval = 90

    public init() {}

    /// Kill the spawned server immediately (used on app quit).
    public nonisolated func terminateServerNow() {
        processBox.terminate()
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    private static var pidFile: URL {
        SettingsStore.shared.appSupportDir.appendingPathComponent("llama-server.pid")
    }

    /// PID recorded by a previous app instance, if that process is still a
    /// live llama-server (guards against PID reuse by checking the command).
    private static func stalePid() -> pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // KERN_PROCARGS2 layout: argc (Int32) then NUL-separated exec path + args.
        let path = String(decoding: buffer.dropFirst(4).prefix { $0 != 0 }, as: UTF8.self)
        return path.hasSuffix("llama-server") ? pid : nil
    }

    /// Called at app launch: a server left behind by a crashed/force-quit
    /// instance is holding ~2.5 GB — kill it rather than silently adopting it.
    public nonisolated func reapStaleServer() {
        guard let pid = Self.stalePid() else {
            try? FileManager.default.removeItem(at: Self.pidFile)
            return
        }
        Log.info("Reaping llama-server (pid \(pid)) left by a previous instance")
        kill(pid, SIGTERM)
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    public func cleanDictation(_ text: String) async -> String {
        guard !text.isEmpty else { return text }
        do {
            let output = try await chat(
                system: LLMPrompts.dictationSystem,
                user: text,
                maxTokens: 4096
            )
            // A truncated cleanup would silently lose the tail of what the
            // user said — prefer the raw transcript in that case.
            return (output.text.isEmpty || output.truncated) ? text : output.text
        } catch {
            Log.warn("Dictation cleanup skipped: \(error.localizedDescription)")
            return text
        }
    }

    /// llama-server context window we start with (`-c`). Everything below is
    /// budgeted against it so long meetings never overflow silently.
    static let contextTokens = 16_384
    /// Conservative tokens-per-byte for Czech+English mixed text (Czech
    /// tokenizes at ~2.6 tokens/word). Used only for budgeting.
    static func estimatedTokens(_ text: String) -> Int { text.utf8.count / 2 + 1 }
    /// Largest transcript slice we send in one request. Leaves room for the
    /// system prompt and an answer of similar length within the context.
    static let maxTranscriptTokensPerRequest = 5_000

    /// Structures a meeting transcript. Returns nil when the LLM could not be
    /// used (caller keeps the raw transcript and tells the user).
    ///
    /// Short transcripts get the full treatment (summary, action items,
    /// cleaned transcript). Long ones are split at turn boundaries into slices
    /// that fit the context; each slice yields summary + action items, then a
    /// final pass merges them. The cleaned transcript is skipped for long
    /// meetings — the raw transcript is always saved alongside anyway.
    public func structureMeeting(markdownTranscript: String) async -> String? {
        guard !markdownTranscript.isEmpty else { return nil }
        do {
            let slices = Self.slices(markdownTranscript, maxTokens: Self.maxTranscriptTokensPerRequest)
            if slices.count == 1 {
                let output = try await chat(
                    system: LLMPrompts.meetingSystem,
                    user: LLMPrompts.meetingUser(transcript: markdownTranscript),
                    maxTokens: Self.contextTokens - Self.estimatedTokens(LLMPrompts.meetingSystem + markdownTranscript) - 256
                )
                return output.text.isEmpty ? nil : output.text + (output.truncated ? Self.truncationNote : "")
            }

            Log.info("Long transcript: structuring in \(slices.count) slices")
            var partials: [String] = []
            for (index, slice) in slices.enumerated() {
                let output = try await chat(
                    system: LLMPrompts.meetingPartSystem,
                    user: LLMPrompts.meetingPartUser(part: index + 1, of: slices.count, transcript: slice),
                    maxTokens: 2_048
                )
                if !output.text.isEmpty { partials.append(output.text) }
            }
            guard !partials.isEmpty else { return nil }
            let merged = try await chat(
                system: LLMPrompts.meetingMergeSystem,
                user: LLMPrompts.meetingMergeUser(partials: partials),
                maxTokens: 4_096
            )
            guard !merged.text.isEmpty else { return nil }
            return merged.text + (merged.truncated ? Self.truncationNote : "")
                + "\n\n_(Cleaned transcript omitted for long meetings; the raw transcript follows.)_"
        } catch {
            Log.warn("Meeting structuring skipped: \(error.localizedDescription)")
            return nil
        }
    }

    static let truncationNote = "\n\n_(Output truncated: model context limit reached.)_"

    /// Split a Markdown transcript at turn boundaries (blank lines) into slices
    /// whose estimated token count stays under `maxTokens`.
    static func slices(_ transcript: String, maxTokens: Int) -> [String] {
        let turns = transcript.components(separatedBy: "\n\n")
        var slices: [String] = []
        var current = ""
        for turn in turns {
            let candidate = current.isEmpty ? turn : current + "\n\n" + turn
            if !current.isEmpty, estimatedTokens(candidate) > maxTokens {
                slices.append(current)
                current = turn
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { slices.append(current) }
        return slices
    }

    // MARK: - OpenAI-compatible chat call

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let messages: [Message]
        let temperature: Double
        let max_tokens: Int
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
            let finish_reason: String?
        }

        let choices: [Choice]
    }

    struct ChatOutput {
        var text: String
        var truncated: Bool
    }

    private var inFlightRequests = 0

    private func chat(system: String, user: String, maxTokens: Int) async throws -> ChatOutput {
        try await ensureServerRunning()
        // Re-arm the idle timer on EVERY exit (success, HTTP error, timeout) once
        // the last concurrent request finishes — otherwise a failed request
        // could leave the 2.5 GB server resident forever.
        inFlightRequests += 1
        defer {
            inFlightRequests -= 1
            if inFlightRequests == 0 { scheduleIdleShutdown() }
        }

        let port = SettingsStore.shared.llmPort
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            temperature: 0.3,
            max_tokens: max(256, maxTokens)
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.warn("llama-server HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body.prefix(300))")
            throw LLMError.badResponse
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let choice = decoded.choices.first
        return ChatOutput(
            text: choice?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            truncated: choice?.finish_reason == "length"
        )
    }

    // MARK: - Server lifecycle

    public enum LLMError: Error, LocalizedError {
        case serverBinaryNotFound
        case modelNotFound
        case serverDidNotStart
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .serverBinaryNotFound:
                return "llama-server not found — run scripts/setup_llm.sh"
            case .modelNotFound:
                return "No GGUF model found — run scripts/setup_llm.sh"
            case .serverDidNotStart:
                return "llama-server did not become healthy in time"
            case .badResponse:
                return "llama-server returned an error response"
            }
        }
    }

    /// In-flight startup. The actor is reentrant at each `await` in the
    /// health-poll loop; without this, a dictation cleanup arriving while a
    /// meeting's server is booting would spawn a second llama-server.
    private var startupTask: Task<Void, Error>?

    private func ensureServerRunning() async throws {
        idleShutdownTask?.cancel()
        idleShutdownTask = nil

        if let startupTask {
            try await startupTask.value
            return
        }
        let task = Task<Void, Error> { [self] in try await self.startServerIfNeeded() }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private func startServerIfNeeded() async throws {
        if await healthy() {
            // Someone is serving on our port. If it's a server one of our
            // instances started, adopt it so the idle timer can still kill it.
            if !processBox.isRunning, let pid = Self.stalePid() {
                processBox.adopt(pid: pid)
            }
            return
        }

        let (serverPath, modelPath) = try resolvePaths()
        Log.info("Starting llama-server (\(modelPath))…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(SettingsStore.shared.llmPort),
            "-c", String(Self.contextTokens),
            "-ngl", "99",
            "--jinja",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        processBox.set(process, pidFile: Self.pidFile)

        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if await healthy() {
                Log.info("llama-server ready")
                return
            }
            if !process.isRunning {
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        processBox.terminate()
        throw LLMError.serverDidNotStart
    }

    private func healthy() async -> Bool {
        let port = SettingsStore.shared.llmPort
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func resolvePaths() throws -> (server: String, model: String) {
        let settings = SettingsStore.shared
        let fileManager = FileManager.default

        let serverCandidates = [
            settings.llamaServerPath,
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
        ].compactMap { $0 }
        guard let server = serverCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw LLMError.serverBinaryNotFound
        }

        var model = settings.llmModelPath
        if model == nil || !fileManager.fileExists(atPath: model!) {
            model = try? fileManager
                .contentsOfDirectory(at: settings.modelsDir, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "gguf" }?
                .path
        }
        guard let model, fileManager.fileExists(atPath: model) else {
            throw LLMError.modelNotFound
        }
        return (server, model)
    }

    private func scheduleIdleShutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = Task { [processBox, idleTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(idleTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            Log.info("llama-server idle timeout — shutting down to free RAM")
            processBox.terminate()
        }
    }
}
