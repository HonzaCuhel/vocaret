import Foundation
import WhisperKit

/// Serialized wrapper around WhisperKit. Loads the configured model once
/// (falling back to a smaller one on failure), keeps it warm, and exposes
/// simple string/segment transcription for the rest of the app.
public enum TranscriberError: Error { case engineNotLoaded }

public actor Transcriber {
    public static let shared = Transcriber()

    private var whisper: WhisperKit?
    /// Language of the most recent decode, for callers that want to know what
    /// they are looking at (the vocabulary corrector treats a word differently
    /// inside a Czech sentence than inside an English one).
    private var _lastLanguage: String?
    public var lastLanguage: String? { _lastLanguage }
    /// How many allowed languages to try when Whisper's own pick is not one of
    /// them. Each costs a decode, and the user may have checked twelve.
    static let maxLanguageCandidates = 2
    /// In-flight load. Actors are reentrant at every `await`, so without this
    /// a hotkey press during the (minutes-long, first-launch) load would start
    /// a second download/CoreML load of the same model.
    private var loadTask: Task<WhisperKit, Error>?
    private var unloadTask: Task<Void, Never>?
    /// Invalidates an in-flight load if the user switches engines while the
    /// underlying framework is inside a cancellation-insensitive operation.
    private var modelGeneration = 0
    private var activeMeetings = 0
    private var decodeInProgress = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    // Actors reenter at await; Core ML inference still needs explicit exclusion
    // when live meetings and dictation share the selected model.
    private func acquireDecode() async {
        if !decodeInProgress { decodeInProgress = true; return }
        await withCheckedContinuation { decodeWaiters.append($0) }
    }

    private func releaseDecode() {
        if decodeWaiters.isEmpty { decodeInProgress = false }
        else { decodeWaiters.removeFirst().resume() }
    }

    public var isReady: Bool {
        get async {
            switch ModelLifecyclePolicy.preloadTarget(engine: SettingsStore.shared.asrEngine) {
            case .none:
                return (try? await AsyncAPIKeyAccess.shared.load(.soniox)) != nil
            case .whisper:
                return whisper != nil
            case .parakeet:
                return await ParakeetEngine.shared.isReady
            }
        }
    }

    /// Called at app launch so the first dictation has no model-load latency.
    public func preload() async {
        switch ModelLifecyclePolicy.preloadTarget(engine: SettingsStore.shared.asrEngine) {
        case .none:
            return
        case .parakeet:
            await ParakeetEngine.shared.preload()
        case .whisper:
            _ = try? await ensureLoaded()
        }
    }

    /// Meetings always use a local engine, including when dictation uses Soniox.
    /// Keep it resident through silent stretches instead of reloading mid-call.
    func beginMeeting(engine: String) async {
        activeMeetings += 1
        unloadTask?.cancel()
        unloadTask = nil
        if engine == "parakeet" { await ParakeetEngine.shared.preload() }
        else { _ = try? await ensureLoaded() }
    }

    func endMeeting() async {
        activeMeetings = max(0, activeMeetings - 1)
        guard activeMeetings == 0 else { return }
        if SettingsStore.shared.asrEngine == "soniox" { await unload() }
        else { scheduleUnloadIfConfigured() }
    }

    func transcribeMeetingChunk(samples: [Float], offset: Double, engine: String) async throws -> [SpokenSegment] {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        let kit = engine == "parakeet" ? nil : try await ensureLoaded()
        return try await transcribeChunk(kit, samples, offset: offset)
    }

    public func unload() async {
        modelGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        unloadTask?.cancel()
        unloadTask = nil
        whisper = nil
        _lastLanguage = nil
        await ParakeetEngine.shared.unload()
        Log.info("Whisper model unloaded")
    }

    /// Drop the inactive engine before loading the newly selected local one.
    /// Soniox deliberately stops after unloading so cloud mode consumes no
    /// local ASR model RAM.
    public func selectEngine(_ engine: String) async {
        await unload()
        guard ModelLifecyclePolicy.shouldApplySelection(
            requestedEngine: engine,
            currentEngine: SettingsStore.shared.asrEngine
        ) else { return }
        switch ModelLifecyclePolicy.preloadTarget(engine: engine) {
        case .none:
            return
        case .whisper:
            _ = try? await ensureLoaded()
        case .parakeet:
            await ParakeetEngine.shared.preload()
        }
    }

    private var usingParakeet: Bool { SettingsStore.shared.asrEngine == "parakeet" }

    /// Whisper is only loaded on the Whisper path — Parakeet users should not
    /// pay for (or download) a second model.
    private func engineIfWhisper() async throws -> WhisperKit? {
        usingParakeet ? nil : try await ensureLoaded()
    }

    /// Dictation path: 16 kHz mono samples in, plain text out.
    ///
    /// Short utterances (≤ 30 s, the Whisper window) go through a single
    /// decode so latency stays minimal; longer ones are chunked at silences
    /// like meeting audio so each utterance keeps its own language.
    public func transcribe(samples: [Float]) async throws -> String {
        // Whisper hallucinates on near-empty audio; skip clips under 0.3 s.
        guard samples.count > Int(MicRecorder.whisperSampleRate * 0.3) else { return "" }
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        let kit = try await engineIfWhisper()
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

    /// Soniox fallback is intentionally transient: return both text and the
    /// detected language, then release the local model even when the user's
    /// normal preference is to keep local engines warm.
    func transcribeCloudFallback(samples: [Float]) async throws -> (text: String, language: String?) {
        let fallbackGeneration = modelGeneration
        do {
            let text = try await transcribe(samples: samples)
            let output = (text: text, language: _lastLanguage)
            await unloadCloudFallbackIfStillOwned(generation: fallbackGeneration)
            return output
        } catch {
            await unloadCloudFallbackIfStillOwned(generation: fallbackGeneration)
            throw error
        }
    }

    private func unloadCloudFallbackIfStillOwned(generation: Int) async {
        guard activeMeetings == 0, ModelLifecyclePolicy.shouldUnloadCloudFallback(
            startingGeneration: generation,
            currentGeneration: modelGeneration,
            currentEngine: SettingsStore.shared.asrEngine
        ) else { return }
        await unload()
    }

    /// Meeting path: audio file in, timestamped segments out. Always chunked
    /// per utterance so bilingual conversations keep both languages — and
    /// every chunk is detected on its own, as in dictation: a one-word
    /// "Yes" after a Czech turn must not be decoded as Czech.
    public func transcribe(fileURL: URL) async throws -> [SpokenSegment] {
        await acquireDecode()
        defer { releaseDecode() }
        try Task.checkCancellation()
        let kit = try await engineIfWhisper()
        defer { scheduleUnloadIfConfigured() }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)
        return try await transcribeChunked(kit, samples)
    }

    // MARK: - Chunked / language-aware decoding

    private func transcribeChunked(_ kit: WhisperKit?, _ samples: [Float]) async throws -> [SpokenSegment] {
        let ranges = UtteranceChunker().chunks(in: samples)
        // No speech at all → no transcript. Feeding silence to Whisper only
        // yields hallucinated subtitle credits.
        guard !ranges.isEmpty else { return [] }
        Log.info("Transcribing \(ranges.count) utterance chunk(s) from \(String(format: "%.1f", Double(samples.count) / MicRecorder.whisperSampleRate))s of audio")
        var segments: [SpokenSegment] = []
        for range in ranges {
            try Task.checkCancellation()
            let offset = Double(range.lowerBound) / MicRecorder.whisperSampleRate
            segments += try await transcribeChunk(kit, Array(samples[range]), offset: offset)
        }
        return segments
    }

    /// One Whisper window (≤ 30 s). Language policy:
    /// - forced (an explicit language code): decode with that token.
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

    private func transcribeChunk(_ kit: WhisperKit?, _ rawSamples: [Float], offset: Double) async throws -> [SpokenSegment] {
        let settings = SettingsStore.shared
        let selectedLanguage = settings.language
        let allowed = settings.autoLanguages
        _lastLanguage = nil
        if kit == nil {
            // Parakeet: no zero-padding (it hurts short clips there), one segment
            // per chunk, no per-language re-decode (not language-conditioned).
            let hint = selectedLanguage == "auto" ? nil : selectedLanguage
            let (text, confidence) = try await ParakeetEngine.shared.transcribe(samples: rawSamples, language: hint)
            let clean = Self.sanitize(text)
            if confidence < 0.6 { Log.warn("Parakeet low confidence \(confidence) for chunk at \(offset)s") }
            guard !clean.isEmpty else { return [] }
            _lastLanguage = hint
            return [SpokenSegment(start: offset, end: offset + Double(rawSamples.count) / MicRecorder.whisperSampleRate, text: clean)]
        }
        guard let kit else { throw TranscriberError.engineNotLoaded }
        let samples = Self.padded(rawSamples)
        // Detect every automatic chunk independently. A short German sentence
        // must not inherit Czech from a previous dictation or meeting turn.
        var results = try await kit.transcribe(
            audioArray: samples, decodeOptions: Self.decodeOptions(language: selectedLanguage)
        )
        if selectedLanguage == "auto" {
            if !allowed.isEmpty, let detected = results.first?.language, !allowed.contains(detected) {
                // Respect an explicitly restricted set. WhisperKit's
                // detectLangauge() exposes only its rejected top-1 language,
                // so compare actual allowed-language decodes by confidence.
                let candidates = Array(allowed.prefix(Self.maxLanguageCandidates))
                var best: (language: String, score: Float, results: [TranscriptionResult])?
                for candidate in candidates {
                    let attempt = try await kit.transcribe(audioArray: samples, decodeOptions: Self.decodeOptions(language: candidate))
                    let segments = attempt.flatMap(\.segments).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                    guard !segments.isEmpty else { continue }
                    let score = segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
                    if score > (best?.score ?? -.infinity) { best = (candidate, score, attempt) }
                }
                if let best {
                    Log.info("Whisper detected '\(detected)' (not allowed); using '\(best.language)' (avgLogProb \(best.score))")
                    results = best.results
                }
            }
        }
        _lastLanguage = results.first?.language ?? (selectedLanguage == "auto" ? nil : selectedLanguage)
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
        let generation = modelGeneration
        if let loadTask {
            let kit = try await loadTask.value
            guard generation == modelGeneration else { throw CancellationError() }
            return kit
        }

        let task = Task<WhisperKit, Error> { [self] in
            let wanted = SettingsStore.shared.whisperModel
            do {
                let kit = try await self.load(model: wanted)
                try Task.checkCancellation()
                return kit
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                Log.warn("Whisper model '\(wanted)' failed to load (\(error.localizedDescription)); trying fallback")
                let kit = try await self.load(model: SettingsStore.fallbackWhisperModel)
                try Task.checkCancellation()
                return kit
            }
        }
        loadTask = task
        defer {
            if generation == modelGeneration { loadTask = nil }
        }
        let kit = try await task.value
        guard generation == modelGeneration else { throw CancellationError() }
        whisper = kit
        return kit
    }

    /// Where WhisperKit/HubApi materialize a model under our downloadBase.
    private static func localModelFolder(for model: String) -> URL {
        SettingsStore.shared.modelsDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
    }

    static func modelConfiguration(model: String, modelsDir: URL) -> WhisperKitConfig {
        let localFolder = modelsDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
        let isLocal = FileManager.default.fileExists(
            atPath: localFolder.appendingPathComponent("TextDecoder.mlmodelc").path
        )

        // Offline-first: when the model is already on disk, point WhisperKit at
        // the folder with downloads disabled. Otherwise WhisperKit's download
        // path performs a network listing on EVERY launch and fails offline.
        // Keep the tokenizer here too. WhisperKit otherwise puts it in
        // Documents/huggingface, where iCloud can evict it and a synchronous
        // config read can stall waiting for file-provider hydration.
        return WhisperKitConfig(
            model: model,
            downloadBase: modelsDir,
            modelFolder: isLocal ? localFolder.path : nil,
            tokenizerFolder: modelsDir,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: !isLocal
        )
    }

    private func load(model: String) async throws -> WhisperKit {
        let config = Self.modelConfiguration(model: model, modelsDir: SettingsStore.shared.modelsDir)
        Log.info("Loading Whisper model '\(model)' (\(config.download ? "download" : "local"))…")
        let kit = try await WhisperKit(config)
        // Silence warm-up (2 s: WhisperKit skips windows ≤ 1 s) so the first
        // real dictation is instant. Result discarded.
        _ = try? await kit.transcribe(
            audioArray: [Float](repeating: 0, count: Int(MicRecorder.whisperSampleRate * Self.minimumDecodeSeconds)),
            decodeOptions: Self.decodeOptions(language: "en")
        )
        Log.info("Whisper model '\(model)' ready")
        return kit
    }

    /// When the user opts out of keeping the model resident, drop it after
    /// 10 idle minutes so the RAM (mostly mmapped weights) is fully returned.
    private func scheduleUnloadIfConfigured() {
        guard activeMeetings == 0, !SettingsStore.shared.keepModelLoaded else { return }
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    // MARK: - Options

    /// `nil` or `"auto"` → detect this audio; otherwise force the chosen token.
    /// Chunking is ours (UtteranceChunker), so WhisperKit's own is left off.
    static func decodeOptions(language: String?) -> DecodingOptions {
        if let language, language != "auto" {
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
