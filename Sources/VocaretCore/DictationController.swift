import AppKit

private enum LiveDictationConfigurationError: Error, LocalizedError {
    case missingSonioxKey

    var errorDescription: String? {
        switch self {
        case .missingSonioxKey:
            return "Add your Soniox API key in Settings before selecting live transcription."
        }
    }
}

private struct LiveAudioFeedError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Freeze the hold duration at the first release so startup latency and a
/// duplicate release cannot turn a quick toggle tap into push-to-talk.
struct DictationGestureState {
    private var pressStarted: Date?
    private var releasedDuration: TimeInterval?

    var isHeld: Bool { pressStarted != nil }
    var wasReleased: Bool { releasedDuration != nil }

    mutating func begin(at time: Date) {
        pressStarted = time
        releasedDuration = nil
    }

    mutating func release(at time: Date) {
        guard let pressStarted else { return }
        releasedDuration = time.timeIntervalSince(pressStarted)
        self.pressStarted = nil
    }

    func heldDuration(at time: Date) -> TimeInterval {
        releasedDuration ?? pressStarted.map { time.timeIntervalSince($0) } ?? 0
    }
}

/// Hotkey → record → transcribe → (optionally clean) → paste at caret.
@MainActor
public final class DictationController {
    public enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    public private(set) var state: State = .idle {
        didSet { CompanionModel.shared.capturing = state != .idle; onStateChange?(state) }
    }

    public var transcriptDestination: (() -> ((String) -> Void)?)?
    private var recordingDestination: ((String) -> Void)?
    public var onStateChange: ((State) -> Void)?

    private let recorder = MicRecorder()
    /// Guards the async gap in start() (permission prompt) against a second
    /// hotkey press starting a second recording.
    private var isStarting = false
    /// The transcribe/clean/paste job, kept so Esc can abort a slow cleanup.
    private var job: Task<Void, Never>?
    private var jobGeneration = 0
    private var activeJobGeneration: Int?

    /// A transcription started while the user was still holding the hotkey,
    /// during a pause in speech. `sampleCount` is how much audio it covers, so
    /// finish() can check that nothing was said afterwards before trusting it.
    private var speculative: (sampleCount: Int, task: Task<String, Error>)?
    private var speechWatcher: Task<Void, Never>?
    private var liveSession: (any LiveTranscriptionSession)?
    private var liveAudioBuffer: LiveAudioChunkBuffer?
    private var liveAudioTask: Task<String?, Never>?
    /// Ownership moves here after recording stops so Esc can still close a
    /// stalled, potentially billable cloud stream while finalization is active.
    private var finishingLiveSession: (any LiveTranscriptionSession)?
    private var finishingLiveAudioTask: Task<String?, Never>?
    private var finishingLiveOwner: Int?
    private var recordingEngine = "whisper"


    public init() {}

    /// Shorter than this and the press counts as a tap (toggle mode) rather
    /// than a hold, so a quick tap-speak-tap still works.
    private static let holdThreshold: TimeInterval = 0.35
    private var gesture = DictationGestureState()

    /// Hotkey went down.
    public func toggle() {
        switch state {
        case .idle:
            guard !isStarting, !CompanionModel.shared.capturing else { return }
            CompanionModel.shared.capturing = true
            if CompanionModel.shared.mode == .meeting { CompanionModel.shared.mode = .dictation }
            gesture.begin(at: Date())
            start()
        case .recording:
            gesture = DictationGestureState()
            finish()
        case .transcribing:
            break // ignore presses while a transcription is in flight; Esc cancels
        }
    }

    /// Hotkey came back up. In push-to-talk mode a held key ends the recording
    /// and inserts immediately; a quick tap leaves it recording until the next
    /// press.
    public func hotkeyReleased() {
        guard SettingsStore.shared.pushToTalk, gesture.isHeld else { return }
        gesture.release(at: Date())
        // Released before the mic finished starting (permission check, engine
        // start): remember it so start() can honour it instead of recording on.
        if isStarting {
            return
        }
        guard state == .recording, gesture.heldDuration(at: Date()) >= Self.holdThreshold else { return }
        gesture = DictationGestureState()
        finish()
    }

    public func cancel() {
        switch state {
        case .recording:
            HotkeyManager.shared.endReleaseWatch()
            cancelSpeculation()
            cancelLiveCapture()
            _ = recorder.stop()
            MediaPauser.shared.resumeIfPaused()
            unregisterCancelHotkey()
            SoundPlayer.play(.stop)
            HUD.shared.hide()
            state = .idle
        case .transcribing:
            let cancelledGeneration = activeJobGeneration
            job?.cancel()
            if let cancelledGeneration {
                cancelFinishingLiveCapture(ownedBy: cancelledGeneration)
                if DictationJobOwnership.isCurrent(
                    cancelledGeneration,
                    activeGeneration: activeJobGeneration
                ) {
                    activeJobGeneration = nil
                    job = nil
                }
            }
            unregisterCancelHotkey()
            HUD.shared.flash("Dictation cancelled")
            state = .idle
        case .idle:
            break
        }
    }

    /// Called on app quit while recording: stop the engine cleanly.
    public func stopForTermination() {
        guard state == .recording else { return }
        cancelSpeculation()
        cancelLiveCapture()
        _ = recorder.stop()
        MediaPauser.shared.resumeIfPausedNow()
        state = .idle
    }

    private func start() {
        recordingDestination = transcriptDestination?()
        isStarting = true
        Task { @MainActor in
            defer { isStarting = false; if state == .idle { CompanionModel.shared.capturing = false } }
            guard await Permissions.requestMicrophone() else {
                HUD.shared.flash("Microphone access denied — enable it in System Settings")
                Permissions.openMicrophoneSettings()
                return
            }
            guard state == .idle else { return }
            recordingEngine = SettingsStore.shared.asrEngine
            do {
                try await prepareLiveCaptureIfNeeded(engine: recordingEngine)
                try recorder.startInMemory()
            } catch {
                cancelLiveCapture()
                SoundPlayer.play(.error)
                HUD.shared.flash("Could not start recording: \(error.localizedDescription)")
                return
            }
            recorder.onInterrupted = { [weak self] error in
                self?.handleInterruption(error)
            }
            SoundPlayer.play(.start)
            state = .recording
            if recordingEngine != "soniox" { startSpeechWatcher() }
            MediaPauser.shared.pauseIfPlaying()
            // Hide the LLM cold start behind the time the user spends speaking.
            if SettingsStore.shared.cleanDictation {
                DictationCleanup.warmUp(model: SettingsStore.shared.dictationCleanupModel)
            }
            if SettingsStore.shared.pushToTalk {
                let settings = SettingsStore.shared
                HotkeyManager.shared.beginReleaseWatch(
                    keyCode: settings.dictationKeyCode,
                    modifiers: settings.dictationModifiers
                ) { [weak self] in
                    self?.hotkeyReleased()
                }
            }
            let hotkey = SettingsStore.shared.dictationHotkeyLabel
            let heldDuration = gesture.heldDuration(at: Date())
            let holding = SettingsStore.shared.pushToTalk && gesture.isHeld
            HUD.shared.beginRecording(
                status: recordingEngine == "soniox" ? L("Live · Soniox") : L("Local transcription"),
                hint: holding
                    ? "\(L("Release to insert")) · \(hotkey) · \(L("Esc cancels"))"
                    : "\(L("Press to insert")) · \(hotkey) · \(L("Esc cancels"))",
                level: { [weak recorder] in recorder?.level ?? 0 }
            )
            registerCancelHotkey()

            // The key was already let go while we were starting up.
            if gesture.wasReleased, SettingsStore.shared.pushToTalk, heldDuration >= Self.holdThreshold {
                gesture = DictationGestureState()
                finish()
            }
        }
    }

    private func handleInterruption(_ error: Error?) {
        guard state == .recording else { return }
        Log.warn("Dictation recording interrupted: \(error?.localizedDescription ?? "audio device changed")")
        // Keep what we have; the user can stop normally. Just tell them.
        HUD.shared.update("Audio device changed — press the hotkey to insert")
    }

    private func prepareLiveCaptureIfNeeded(engine: String) async throws {
        guard engine == "soniox" else { return }
        guard let apiKey = try await AsyncAPIKeyAccess.shared.load(.soniox) else {
            throw LiveDictationConfigurationError.missingSonioxKey
        }

        let settings = SettingsStore.shared
        let languageHints = settings.language == "auto" ? settings.autoLanguages : [settings.language]
        let terms = Self.sonioxTerms(from: Vocabulary.shared.terms)
        let configuration = SonioxConfiguration(
            apiKey: apiKey,
            region: SonioxRegion(rawValue: settings.sonioxRegion) ?? .eu,
            languageHints: languageHints,
            terms: terms
        )
        let session = SonioxTranscriber(configuration: configuration)
        try await session.start { partial in
            await MainActor.run { HUD.shared.updatePartial(partial) }
        }

        let buffer = LiveAudioChunkBuffer(capacity: 64)
        liveSession = session
        liveAudioBuffer = buffer
        recorder.onSamples = { samples in buffer.yield(samples) }
        liveAudioTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for await samples in buffer.stream {
                    try Task.checkCancellation()
                    guard !buffer.hasOverflowed else {
                        throw LiveAudioFeedError(
                            message: "Soniox audio buffering overflowed while the connection was stalled."
                        )
                    }
                    try await session.append(samples)
                }
                guard !buffer.hasOverflowed else {
                    throw LiveAudioFeedError(
                        message: "Soniox audio buffering overflowed while the connection was stalled."
                    )
                }
                return nil
            } catch {
                buffer.finish()
                await session.cancel()
                await MainActor.run { [weak self] in
                    // A cancelled older session must never change a newer HUD.
                    guard let self, self.state == .recording,
                          self.liveAudioBuffer === buffer else { return }
                    self.recorder.onSamples = nil
                    HUD.shared.update(L("Cloud unavailable · Recording continues locally"))
                    Log.warn("Live dictation feed failed; microphone capture continues for local recovery")
                }
                return error.localizedDescription
            }
        }
    }

    private func cancelLiveCapture() {
        recorder.onSamples = nil
        liveAudioBuffer?.finish()
        liveAudioBuffer = nil
        liveAudioTask?.cancel()
        liveAudioTask = nil
        if let liveSession {
            Task { await liveSession.cancel() }
        }
        liveSession = nil
    }

    private func cancelFinishingLiveCapture(ownedBy owner: Int? = nil) {
        if let owner, finishingLiveOwner != owner { return }
        finishingLiveAudioTask?.cancel()
        finishingLiveAudioTask = nil
        if let finishingLiveSession {
            Task { await finishingLiveSession.cancel() }
        }
        finishingLiveSession = nil
        finishingLiveOwner = nil
    }

    /// Soniox accepts up to 10,000 context characters. Leave margin for JSON
    /// and future context fields while keeping user vocabulary order stable.
    private static func sonioxTerms(from terms: [String]) -> [String] {
        var result: [String] = []
        var bytes = 0
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let nextBytes = trimmed.utf8.count + 1
            guard bytes + nextBytes <= 8_000 else { break }
            result.append(trimmed)
            bytes += nextBytes
        }
        return result
    }

    /// While recording, watch for a pause in speech and start transcribing what
    /// we have so far. People pause before they let go of the key, so by the
    /// time they do the text is usually already decoded — which is where the
    /// perceived latency of a dictation actually goes.
    private func startSpeechWatcher() {
        speechWatcher?.cancel()
        speechWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.speculateIfSpeechPaused()
            }
        }
    }

    private func speculateIfSpeechPaused() async {
        guard state == .recording else { return }
        let activity = recorder.activitySnapshot()
        guard SpeechPause.shouldSpeculate(
            on: activity,
            alreadySpeculatedCount: speculative?.sampleCount ?? 0
        ) else { return }

        // The full copy is now made only when a real pause triggers a decode,
        // not on every 150 ms watcher tick.
        let samples = recorder.snapshot()

        speculative?.task.cancel()
        let rate = MicRecorder.whisperSampleRate
        let count = samples.count
        let task = Task.detached(priority: .userInitiated) {
            try await Transcriber.shared.transcribe(samples: samples)
        }
        speculative = (count, task)
        Task { [weak self] in
            guard let text = try? await task.value,
                  let self,
                  self.state == .recording,
                  self.speculative?.sampleCount == count else { return }
            HUD.shared.updatePartial(text)
        }
        Log.info("Speculating on \(String(format: "%.1f", Double(count) / rate))s after a pause")
    }

    private func cancelSpeculation() {
        speechWatcher?.cancel()
        speechWatcher = nil
        speculative?.task.cancel()
        speculative = nil
    }

    /// The speculative result is only usable if the audio recorded after it was
    /// silence — otherwise the user said something it never heard.
    private func usableSpeculation(finalSamples: [Float]) -> Task<String, Error>? {
        guard let speculative else { return nil }
        guard SpeechPause.covers(speculative.sampleCount, of: finalSamples) else {
            Log.info("Speech continued after the pause — transcribing the whole clip")
            return nil
        }
        return speculative.task
    }

    private func finish() {
        let destination = recordingDestination
        jobGeneration &+= 1
        let thisJobGeneration = jobGeneration
        activeJobGeneration = thisJobGeneration
        HotkeyManager.shared.endReleaseWatch()
        speechWatcher?.cancel()
        speechWatcher = nil
        let samples = recorder.stop()
        recorder.onSamples = nil
        let headStart = usableSpeculation(finalSamples: samples)
        speculative = nil

        // Stop accepting chunks, then let the one feed task drain every chunk
        // already captured before asking Soniox to finalize.
        liveAudioBuffer?.finish()
        liveAudioBuffer = nil
        let sessionBeingFinalized = liveSession
        let audioTaskBeingFinalized = liveAudioTask
        liveSession = nil
        liveAudioTask = nil
        finishingLiveSession = sessionBeingFinalized
        finishingLiveAudioTask = audioTaskBeingFinalized
        finishingLiveOwner = thisJobGeneration

        MediaPauser.shared.resumeIfPaused()
        let recordingSeconds = Double(samples.count) / MicRecorder.whisperSampleRate
        let transcriptionStarted = Date()
        let engine = recordingEngine
        let shouldClean = SettingsStore.shared.cleanDictation
        let cleanupModel = SettingsStore.shared.dictationCleanupModel
        SoundPlayer.play(.stop)
        state = .transcribing
        HUD.shared.beginTranscribing(
            status: engine == "soniox" ? L("Finalizing…") : L("Transcribing locally…"),
            hint: L("Esc cancels")
        )
        // Remember where the text should go — the user may switch apps while
        // we transcribe, and we must not paste into an unrelated window.
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        job = Task { @MainActor in
            defer {
                cancelFinishingLiveCapture(ownedBy: thisJobGeneration)
                if DictationJobOwnership.isCurrent(
                    thisJobGeneration,
                    activeGeneration: activeJobGeneration
                ) {
                    activeJobGeneration = nil
                    unregisterCancelHotkey()
                    if state == .transcribing { state = .idle }
                    job = nil
                }
            }
            do {
                let hasLocalSpeech = !UtteranceChunker().chunks(in: samples).isEmpty
                var cloudText: String?
                var cloudLanguage: String?
                var cloudFailure: String?
                if let sessionBeingFinalized {
                    if let feedFailure = await audioTaskBeingFinalized?.value {
                        cloudFailure = feedFailure
                        await sessionBeingFinalized.cancel()
                    } else {
                        do {
                            let finalized = try await sessionBeingFinalized.finish()
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if finalized.isEmpty {
                                cloudFailure = "Soniox finalized without a transcript."
                            } else {
                                cloudText = finalized
                                cloudLanguage = await sessionBeingFinalized.detectedLanguage()
                            }
                        } catch {
                            try Task.checkCancellation()
                            cloudFailure = error.localizedDescription
                        }
                    }
                }
                try Task.checkCancellation()

                let cloudResult = LiveDictationPolicy.cloudResult(
                    engine: engine,
                    transcript: cloudText
                )
                let nextStep = LiveDictationPolicy.nextStep(
                    engine: engine,
                    cloudResult: cloudResult,
                    hasLocalSpeech: hasLocalSpeech
                )

                var text: String
                var modelLabel: String
                var transcriptLanguage: String?
                switch nextStep {
                case .useCloudTranscript:
                    text = cloudText ?? ""
                    modelLabel = "Soniox stt-rt-v5"
                    transcriptLanguage = SettingsStore.shared.language == "auto"
                        ? cloudLanguage
                        : SettingsStore.shared.language
                case .transcribeLocally:
                    if let cloudFailure {
                        Log.warn("Soniox unavailable; using retained local audio (\(cloudFailure))")
                        HUD.shared.clearPartial()
                        HUD.shared.update(L("Cloud unavailable · Local fallback"))
                    }
                    if engine == "soniox" {
                        let fallback = try await Transcriber.shared.transcribeCloudFallback(samples: samples)
                        text = fallback.text
                        transcriptLanguage = fallback.language
                    } else if let headStart {
                        text = try await headStart.value
                        transcriptLanguage = await Transcriber.shared.lastLanguage
                    } else {
                        text = try await Transcriber.shared.transcribe(samples: samples)
                        transcriptLanguage = await Transcriber.shared.lastLanguage
                    }
                    modelLabel = Self.localModelLabel(for: engine)
                case .noTranscript:
                    text = ""
                    modelLabel = engine == "soniox" ? "Soniox stt-rt-v5" : Self.localModelLabel(for: engine)
                    transcriptLanguage = nil
                }

                try Task.checkCancellation()
                if text.isEmpty {
                    HUD.shared.flash("Nothing recognized")
                    return
                }
                let cleanup: ((String) async -> DictationCleanupResult)?
                if shouldClean {
                    HUD.shared.updatePartial(text)
                    HUD.shared.update(cleanupModel == "gpt-5-nano"
                        ? L("Formatting with GPT-5 nano…")
                        : L("Cleaning with local AI…"))
                    cleanup = { await DictationCleanup.process($0, model: cleanupModel) }
                } else {
                    cleanup = nil
                }
                let finalized = try await DictationFinalizer.finalize(
                    rawText: text,
                    recordingSeconds: recordingSeconds,
                    transcriptionStarted: transcriptionStarted,
                    model: modelLabel,
                    cleanup: cleanup,
                    learnCorrections: { Vocabulary.shared.learn(from: $0, to: $1) },
                    correct: {
                        TranscriptCorrector.apply($0, vocabulary: Vocabulary.shared, language: transcriptLanguage)
                    }
                )
                try await DictationFinalizer.deliver(
                    finalized,
                    history: .shared,
                    present: {
                        CompanionModel.shared.noteDictation($0)
                        HUD.shared.updatePartial($0)
                    },
                    insert: {
                        if let destination {
                            destination($0)
                            return nil
                        }
                        return await TextInserter.insert($0, targetPID: targetPID)
                    }
                )
                if let failure = finalized.cleanupFailure {
                    HUD.shared.flash(failure == .unavailable
                        ? L("Formatting unavailable · Unformatted dictation saved")
                        : L("Formatting failed · Unformatted dictation saved"), seconds: 4)
                } else {
                    HUD.shared.hide(immediately: true)
                }
            } catch is CancellationError {
                // cancel() already updated the HUD/state.
            } catch {
                SoundPlayer.play(.error)
                HUD.shared.flash("Transcription failed: \(error.localizedDescription)", seconds: 4)
                Log.error("Dictation failed: \(error)")
            }
        }
    }

    private static func localModelLabel(for engine: String) -> String {
        engine == "parakeet" ? ParakeetEngine.modelLabel : SettingsStore.shared.whisperModel
    }

    private func registerCancelHotkey() {
        try? HotkeyManager.shared.register(id: HotkeyID.cancel, keyCode: 53, modifiers: 0) { [weak self] in
            self?.cancel()
        }
    }

    private func unregisterCancelHotkey() {
        HotkeyManager.shared.unregister(id: HotkeyID.cancel)
    }
}
