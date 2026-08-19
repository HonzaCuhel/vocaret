import FluidAudio
import Foundation

/// NVIDIA Parakeet-TDT-0.6B-v3 via FluidAudio (Core ML, Neural Engine).
///
/// Optional, non-default engine. Faster than Whisper large-v3-turbo and on par
/// for Czech on read speech (FLEURS 11.0 % vs 11.3 %), but it has NO language
/// conditioning and a documented English-prior fallback on short or
/// spontaneous non-English clips. Vocaret's per-utterance chunking removes the
/// worst failure (one language of a mixed window silently dropped), which is
/// why it is offered at all — behind a setting, for the user to benchmark.
public actor ParakeetEngine {
    public static let shared = ParakeetEngine()

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    public var isReady: Bool { manager != nil }

    private func ensureLoaded() async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }
        let task = Task<AsrManager, Error> {
            Log.info("Loading Parakeet TDT v3…")
            let dir = SettingsStore.shared.modelsDir.appendingPathComponent("parakeet", isDirectory: true)
            let models = try await AsrModels.downloadAndLoad(to: dir, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Log.info("Parakeet ready")
            return manager
        }
        loadTask = task
        defer { loadTask = nil }
        let m = try await task.value
        manager = m
        return m
    }

    public func preload() async { _ = try? await ensureLoaded() }

    public func unload() { manager = nil }

    /// Transcribe one utterance chunk (16 kHz mono). Returns text + a
    /// confidence in 0…1 as reported by the decoder.
    public func transcribe(samples: [Float], language: String?) async throws -> (text: String, confidence: Float) {
        let manager = try await ensureLoaded()
        var state = try TdtDecoderState()
        // Parakeet is not language-conditioned; the hint only filters tokens of
        // other scripts (e.g. Cyrillic), so it is passed but not relied on.
        let hint: Language? = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), result.confidence)
    }
}
