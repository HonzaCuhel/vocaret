import Foundation
import WhisperKit

/// Serialized wrapper around WhisperKit. Loads the configured model once
/// (falling back to a smaller one on failure), keeps it warm, and exposes
/// simple string/segment transcription for the rest of the app.
public actor Transcriber {
    public static let shared = Transcriber()

    private var whisper: WhisperKit?
    /// In-flight load. Actors are reentrant at every `await`, so without this
    /// a hotkey press during the (minutes-long, first-launch) load would start
    /// a second download/CoreML load of the same model.
    private var loadTask: Task<WhisperKit, Error>?
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
    ///
    /// Short utterances (≤ 30 s, the Whisper window) go through a single
    /// decode so latency stays minimal; longer ones are chunked at silences
    /// like meeting audio so each utterance keeps its own language.
    public func transcribe(samples: [Float]) async throws -> String {
        // Whisper hallucinates on near-empty audio; skip clips under 0.3 s.
        guard samples.count > Int(MicRecorder.whisperSampleRate * 0.3) else { return "" }
        let kit = try await ensureLoaded()
        defer { scheduleUnloadIfConfigured() }

        let windowSamples = Int(MicRecorder.whisperSampleRate * 30)
        if samples.count <= windowSamples {
            // Whisper hallucinates on silence ("Titulky vytvořil JohnyX.",
            // "Thank you." …) — only decode if the VAD finds actual speech.
            guard !UtteranceChunker().chunks(in: samples).isEmpty else { return "" }
            let segments = try await transcribeChunk(kit, samples, offset: 0)
            return segments.map(\.text).joined(separator: " ")
        }
        let segments = try await transcribeChunked(kit, samples)
        return segments.map(\.text).joined(separator: " ")
    }

    /// Meeting path: audio file in, timestamped segments out. Always chunked
    /// per utterance so bilingual conversations keep both languages.
    public func transcribe(fileURL: URL) async throws -> [SpokenSegment] {
        let kit = try await ensureLoaded()
        defer { scheduleUnloadIfConfigured() }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)
        return try await transcribeChunked(kit, samples)
    }

    // MARK: - Chunked / language-aware decoding

    private func transcribeChunked(_ kit: WhisperKit, _ samples: [Float]) async throws -> [SpokenSegment] {
        let ranges = UtteranceChunker().chunks(in: samples)
        // No speech at all → no transcript. Feeding silence to Whisper only
        // yields hallucinated subtitle credits.
        guard !ranges.isEmpty else { return [] }
        Log.info("Transcribing \(ranges.count) utterance chunk(s) from \(String(format: "%.1f", Double(samples.count) / MicRecorder.whisperSampleRate))s of audio")
        var segments: [SpokenSegment] = []
        for range in ranges {
            let offset = Double(range.lowerBound) / MicRecorder.whisperSampleRate
            segments += try await transcribeChunk(kit, Array(samples[range]), offset: offset)
        }
        return segments
    }

    /// One Whisper window (≤ 30 s). Language policy:
    /// - forced (settings.language = cs/en): decode with that token.
    /// - auto: decode with Whisper's own detection (no extra encoder pass);
    ///   if it picked a language outside `autoLanguages`, re-detect restricted
    ///   to the allowed set and decode again with that token forced.
    /// WhisperKit clips `windowClipTime` (1 s) off the end of every window and
    /// decodes nothing if less than that remains — so a 0.9 s "Ano." would
    /// vanish. Trailing zeros are harmless (Whisper pads to 30 s anyway).
    static let minimumDecodeSeconds = 2.0

    static func padded(_ samples: [Float]) -> [Float] {
        let minimum = Int(MicRecorder.whisperSampleRate * minimumDecodeSeconds)
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    private func transcribeChunk(_ kit: WhisperKit, _ rawSamples: [Float], offset: Double) async throws -> [SpokenSegment] {
        let samples = Self.padded(rawSamples)
        let settings = SettingsStore.shared
        var results: [TranscriptionResult]
        if settings.language == "auto" {
            results = try await kit.transcribe(audioArray: samples, decodeOptions: decodeOptions(language: nil))
            let allowed = settings.autoLanguages
            if !allowed.isEmpty, let detected = results.first?.language, !allowed.contains(detected) {
                let probs = try await kit.detectLangauge(audioArray: samples).langProbs
                if let best = allowed.max(by: { (probs[$0] ?? -.infinity) < (probs[$1] ?? -.infinity) }) {
                    Log.info("Whisper detected '\(detected)' (not allowed); re-decoding as '\(best)'")
                    results = try await kit.transcribe(audioArray: samples, decodeOptions: decodeOptions(language: best))
                }
            }
        } else {
            results = try await kit.transcribe(audioArray: samples, decodeOptions: decodeOptions(language: settings.language))
        }
        return results.flatMap { result in
            result.segments.map { segment in
                SpokenSegment(
                    start: Double(segment.start) + offset,
                    end: Double(segment.end) + offset,
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
        if let loadTask { return try await loadTask.value } // join the in-flight load

        let task = Task<WhisperKit, Error> { [self] in
            let wanted = SettingsStore.shared.whisperModel
            do {
                return try await self.load(model: wanted)
            } catch {
                Log.warn("Whisper model '\(wanted)' failed to load (\(error.localizedDescription)); trying fallback")
                return try await self.load(model: SettingsStore.fallbackWhisperModel)
            }
        }
        loadTask = task
        defer { loadTask = nil }
        let kit = try await task.value
        whisper = kit
        return kit
    }

    /// Where WhisperKit/HubApi materialize a model under our downloadBase.
    private static func localModelFolder(for model: String) -> URL {
        SettingsStore.shared.modelsDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
    }

    private func load(model: String) async throws -> WhisperKit {
        let modelsDir = SettingsStore.shared.modelsDir
        let localFolder = Self.localModelFolder(for: model)
        let isLocal = FileManager.default.fileExists(
            atPath: localFolder.appendingPathComponent("TextDecoder.mlmodelc").path
        )
        Log.info("Loading Whisper model '\(model)' (\(isLocal ? "local" : "download"))…")

        // Offline-first: when the model is already on disk, point WhisperKit at
        // the folder with downloads disabled. Otherwise WhisperKit's download
        // path performs a network listing on EVERY launch and fails offline.
        let config: WhisperKitConfig
        if isLocal {
            config = WhisperKitConfig(
                model: model,
                downloadBase: modelsDir,
                modelFolder: localFolder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
        } else {
            config = WhisperKitConfig(
                model: model,
                downloadBase: modelsDir,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
        }
        let kit = try await WhisperKit(config)
        // Silence warm-up (2 s: WhisperKit skips windows ≤ 1 s) so the first
        // real dictation is instant. Result discarded.
        _ = try? await kit.transcribe(
            audioArray: [Float](repeating: 0, count: Int(MicRecorder.whisperSampleRate * Self.minimumDecodeSeconds)),
            decodeOptions: decodeOptions(language: "en")
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

    /// `language == nil` → let Whisper detect; otherwise force the token.
    /// Chunking is ours (UtteranceChunker), so WhisperKit's own is left off.
    private func decodeOptions(language: String?) -> DecodingOptions {
        if let language {
            return DecodingOptions(language: language, detectLanguage: false)
        }
        return DecodingOptions(detectLanguage: true)
    }

    /// WhisperKit segment text can contain special tokens like <|startoftranscript|>
    /// or timestamp markers <|0.00|>; strip them.
    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
