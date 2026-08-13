import Foundation
import WhisperKit

/// Serialized wrapper around WhisperKit. Loads the configured model once
/// (falling back to a smaller one on failure), keeps it warm, and exposes
/// simple string/segment transcription for the rest of the app.
public actor Transcriber {
    public static let shared = Transcriber()

    private var whisper: WhisperKit?
    private var unloadTask: Task<Void, Never>?

    public var isReady: Bool { whisper != nil }

    /// Called at app launch so the first dictation has no model-load latency.
    public func preload() async {
        _ = try? await ensureLoaded()
    }

    public func unload() {
        unloadTask?.cancel()
        unloadTask = nil
        whisper = nil
        Log.info("Whisper model unloaded")
    }

    /// Dictation path: 16 kHz mono samples in, plain text out.
    public func transcribe(samples: [Float]) async throws -> String {
        // Whisper hallucinates on near-empty audio; skip clips under 0.3 s.
        guard samples.count > Int(MicRecorder.whisperSampleRate * 0.3) else { return "" }
        let kit = try await ensureLoaded()
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: decodeOptions())
        scheduleUnloadIfConfigured()
        let text = results.map(\.text).joined(separator: " ")
        return Self.sanitize(text)
    }

    /// Meeting path: audio file in, timestamped segments out.
    public func transcribe(fileURL: URL) async throws -> [SpokenSegment] {
        let kit = try await ensureLoaded()
        let results = try await kit.transcribe(audioPath: fileURL.path, decodeOptions: decodeOptions())
        scheduleUnloadIfConfigured()
        return results.flatMap { result in
            result.segments.map { segment in
                SpokenSegment(
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: Self.sanitize(segment.text)
                )
            }
        }
        .filter { !$0.text.isEmpty }
    }

    // MARK: - Model lifecycle

    private func ensureLoaded() async throws -> WhisperKit {
        unloadTask?.cancel()
        unloadTask = nil
        if let whisper { return whisper }

        let wanted = SettingsStore.shared.whisperModel
        do {
            let kit = try await load(model: wanted)
            whisper = kit
            return kit
        } catch {
            Log.warn("Whisper model '\(wanted)' failed to load (\(error.localizedDescription)); trying fallback")
            let kit = try await load(model: SettingsStore.fallbackWhisperModel)
            whisper = kit
            return kit
        }
    }

    private func load(model: String) async throws -> WhisperKit {
        Log.info("Loading Whisper model '\(model)'…")
        let config = WhisperKitConfig(
            model: model,
            downloadBase: SettingsStore.shared.modelsDir,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        let kit = try await WhisperKit(config)
        // One-second silence warm-up so the first real dictation is instant.
        _ = try? await kit.transcribe(
            audioArray: [Float](repeating: 0, count: Int(MicRecorder.whisperSampleRate)),
            decodeOptions: decodeOptions()
        )
        Log.info("Whisper model '\(model)' ready")
        return kit
    }

    /// When the user opts out of keeping the model resident, drop it after
    /// 10 idle minutes so the RAM (mostly mmapped weights) is fully returned.
    private func scheduleUnloadIfConfigured() {
        guard !SettingsStore.shared.keepModelLoaded else { return }
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    // MARK: - Options

    private func decodeOptions() -> DecodingOptions {
        let language = SettingsStore.shared.language
        if language == "auto" {
            return DecodingOptions(
                detectLanguage: true,
                chunkingStrategy: .vad
            )
        }
        return DecodingOptions(
            language: language,
            detectLanguage: false,
            chunkingStrategy: .vad
        )
    }

    /// WhisperKit segment text can contain special tokens like <|startoftranscript|>
    /// or timestamp markers <|0.00|>; strip them.
    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
