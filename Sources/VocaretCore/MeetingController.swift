import AppKit

/// Records both sides of a meeting, using local source labels or Soniox voice
/// diarization, then structures with the selected AI provider and saves
/// a Markdown file to ~/Documents/Vocaret/Meetings.
@MainActor
public final class MeetingController {
    public enum State: Equatable {
        case idle
        case recording
        case processing
    }

    public private(set) var state: State = .idle {
        didSet {
            CompanionModel.shared.capturing = state != .idle
            AppModel.shared.meetingState = state
            onStateChange?(state)
        }
    }

    public var onStateChange: ((State) -> Void)?

    private let micRecorder = MicRecorder()
    private var systemTap: Any? // SystemAudioTap, typed loosely for the @available gate
    private var micURL: URL?
    private var systemURL: URL?
    private var startedAt: Date?
    private var recordingStem = ""
    private var isStarting = false
    private var startupTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var finishingSession: (any MeetingSession)?
    private let requestMicrophone: @MainActor () async -> Bool
    private let acknowledgeConsent: (@MainActor () -> Bool)?
    private var liveSession: (any MeetingSession)?
    private var generation = 0
    private var recordingOptions = MeetingProcessingOptions(settings: .shared)

    public init() {
        requestMicrophone = { await Permissions.requestMicrophone() }
        acknowledgeConsent = nil
    }

    init(requestMicrophone: @escaping @MainActor () async -> Bool,
         acknowledgeConsent: @escaping @MainActor () -> Bool) {
        self.requestMicrophone = requestMicrophone
        self.acknowledgeConsent = acknowledgeConsent
    }

    public func toggle() {
        switch state {
        case .idle:
            guard !isStarting, !CompanionModel.shared.capturing else { return }
            CompanionModel.shared.capturing = true
            start()
        case .recording:
            finish()
        case .processing:
            break
        }
    }

    public func cancel() {
        if isStarting {
            generation &+= 1
            startupTask?.cancel()
            startupTask = nil
            isStarting = false
            cancelLiveSession()
            CompanionModel.shared.capturing = false
            unregisterCancelHotkey()
            HUD.shared.hide(immediately: true)
            return
        }
        if state == .processing {
            generation &+= 1
            processingTask?.cancel()
            processingTask = nil
            finishingSession?.cancel()
            finishingSession = nil
            AppModel.shared.meetingStartedAt = nil
            AppModel.shared.meetingStatus = L("Meeting processing cancelled — audio kept for recovery")
            HUD.shared.flash(AppModel.shared.meetingStatus)
            unregisterCancelHotkey()
            state = .idle
            return
        }
        guard state == .recording else { return }
        generation += 1
        stopCapture()
        cancelLiveSession()
        AppModel.shared.liveMeetingTurns = []
        AppModel.shared.meetingStartedAt = nil
        deleteRecordings()
        SoundPlayer.play(.stop)
        HUD.shared.hide(immediately: true)
        unregisterCancelHotkey()
        state = .idle
    }

    /// Called on app quit while recording: closes both WAV writers so the
    /// headers are finalized. Files are kept and can be transcribed later with
    /// `Vocaret --transcribe <file>`.
    public func stopForTermination() {
        if isStarting || state == .processing { cancel(); return }
        guard state == .recording else { return }
        generation += 1
        stopCapture()
        cancelLiveSession()
        MediaPauser.shared.resumeIfPausedNow()
        state = .idle
    }

    /// Recording other participants is regulated (and in some countries a
    /// criminal offence) without their knowledge. Shown once before the first
    /// meeting recording; the user must actively confirm.
    private func consentAcknowledged() -> Bool {
        if SettingsStore.shared.meetingConsentAcknowledged { return true }
        let alert = NSAlert()
        alert.messageText = "Recording a meeting records other people"
        alert.informativeText = """
        This captures your microphone AND everything your Mac plays — including \
        everyone else on the call.

        In many countries you must tell the other participants, and in some \
        (for example Germany) recording a private conversation without consent \
        is a criminal offence. You are responsible for obtaining consent.

        Vocaret saves the transcript on this Mac and deletes raw audio after successful \
        transcription unless you keep it. With Soniox selected, both audio tracks are \
        streamed to Soniox for speaker recognition. GPT-5 nano meeting notes send the \
        transcript text to OpenAI when that model is selected.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "I will get consent")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        SettingsStore.shared.meetingConsentAcknowledged = true
        return true
    }

    private func start() {
        guard #available(macOS 14.4, *) else {
            CompanionModel.shared.capturing = false
            HUD.shared.flash("Meeting capture needs macOS 14.4 or newer")
            return
        }
        guard acknowledgeConsent?() ?? consentAcknowledged() else { CompanionModel.shared.capturing = false; return }
        CompanionModel.shared.capturing = true
        CompanionModel.shared.mode = .meeting
        CompanionModel.shared.expanded = true
        isStarting = true
        generation &+= 1
        let owner = generation
        HUD.shared.beginPreparing(status: L("Preparing meeting…"), hint: L("Esc cancels"))
        registerCancelHotkey()
        startupTask = Task { @MainActor in
            defer {
                if generation == owner {
                    isStarting = false
                    startupTask = nil
                    if state == .idle {
                        CompanionModel.shared.capturing = false
                        unregisterCancelHotkey()
                    }
                }
            }
            let permitted = await requestMicrophone()
            guard generation == owner, !Task.isCancelled else { return }
            guard permitted else {
                HUD.shared.flash("Microphone access denied — enable it in System Settings")
                Permissions.openMicrophoneSettings()
                return
            }
            guard state == .idle else { return }

            let settings = SettingsStore.shared
            let options = MeetingProcessingOptions(settings: settings)
            let configuration: SonioxConfiguration?
            if options.usesCloudSpeech {
                do {
                    guard let key = try await AsyncAPIKeyAccess.shared.load(.soniox) else {
                        guard self.generation == owner, !Task.isCancelled else { return }
                        HUD.shared.flash(L("Add a Soniox API key in Settings before recording a cloud meeting"), seconds: 5)
                        return
                    }
                    guard self.generation == owner, !Task.isCancelled else { return }
                    configuration = SonioxConfiguration(
                        apiKey: key, region: SonioxRegion(rawValue: settings.sonioxRegion) ?? .eu,
                        languageHints: settings.language == "auto" ? settings.autoLanguages : [settings.language],
                        terms: DictationController.sonioxTerms(from: Vocabulary.shared.terms),
                        enableSpeakerDiarization: true
                    )
                } catch {
                    guard self.generation == owner, !Task.isCancelled else { return }
                    HUD.shared.flash(L("Could not read the Soniox key — reconnect in Settings"), seconds: 5)
                    return
                }
            } else { configuration = nil }

            let stem = Self.makeRecordingStem(at: Date())
            let recordingsDir = SettingsStore.shared.recordingsDir
            let micURL = recordingsDir.appendingPathComponent("\(stem)-mic.wav")
            let systemURL = recordingsDir.appendingPathComponent("\(stem)-system.wav")

            recordingOptions = options
            let engine = options.speechEngine
            AppModel.shared.liveMeetingTurns = []
            AppModel.shared.meetingStatus = options.usesCloudSpeech
                ? L("Connecting to Soniox · Recognizing speakers…") : L("Preparing local speech model…")
            let onUpdate: @Sendable (MeetingTranscriptionResult) async -> Void = { result in
                await MainActor.run {
                    guard self.generation == owner, self.state != .idle else { return }
                    let turns = result.turns
                    AppModel.shared.liveMeetingTurns = turns
                    if result.needsRecovery {
                        AppModel.shared.meetingStatus = L("Recording safely — remaining speech will be recovered after finishing")
                    } else if options.usesCloudSpeech {
                        AppModel.shared.meetingStatus = L("Listening · Soniox speaker recognition")
                    }
                    if let turn = turns.last {
                        HUD.shared.updatePartial("\(turn.speaker.localizedLabel): \(turn.text)")
                    }
                }
            }
            let session: any MeetingSession
            if let configuration {
                session = SonioxMeetingSession(configuration: configuration, onUpdate: onUpdate)
            } else {
                session = MeetingTranscriptionSession(
                    prepare: {
                        await Transcriber.shared.beginMeeting(engine: engine)
                        await MainActor.run {
                            guard self.generation == owner, self.state == .recording else { return }
                            AppModel.shared.meetingStatus = L("Listening — speech appears after a short pause")
                        }
                    },
                    decode: { samples, offset in
                        try await Transcriber.shared.transcribeMeetingChunk(samples: samples, offset: offset, engine: engine)
                    },
                    onUpdate: onUpdate
                )
            }
            liveSession = session
            let tap = SystemAudioTap()
            tap.onSamples = { session.append($0, speaker: .them) }
            micRecorder.onSamples = { session.append($0, speaker: .me) }
            do {
                // Tap first: its start triggers the one-time system-audio permission.
                try tap.start(writingTo: systemURL)
                try micRecorder.startToFile(url: micURL)
            } catch {
                tap.stop()
                micRecorder.stop()
                cancelLiveSession()
                try? FileManager.default.removeItem(at: micURL)
                try? FileManager.default.removeItem(at: systemURL)
                SoundPlayer.play(.error)
                if case AudioCaptureError.tapCreationFailed = error {
                    HUD.shared.flash("System audio capture refused — allow Vocaret under System Audio Recording", seconds: 5)
                    Permissions.openAudioCaptureSettings()
                } else {
                    HUD.shared.flash("Could not start meeting capture: \(error.localizedDescription)", seconds: 4)
                }
                Log.error("Meeting capture failed to start: \(error)")
                return
            }
            micRecorder.onInterrupted = { [weak self] error in
                guard let self, self.state == .recording else { return }
                Log.warn("Meeting mic interrupted: \(error?.localizedDescription ?? "device change")")
                HUD.shared.update("● Recording meeting (mic device changed) — \(SettingsStore.shared.meetingHotkeyLabel) to finish")
            }

            self.systemTap = tap
            self.micURL = micURL
            self.systemURL = systemURL
            self.recordingStem = stem
            self.startedAt = Date()
            AppModel.shared.meetingStartedAt = self.startedAt
            SoundPlayer.play(.start)
            state = .recording
            MediaPauser.shared.pauseIfPlaying()
            // Meeting notes are generated after capture. Warming their model
            // here holds a second large model for the entire call.
            HUD.shared.beginRecording(
                status: L(options.usesCloudSpeech ? "Live meeting · Soniox · Speaker recognition" : "Live meeting · On this Mac"),
                hint: "\(SettingsStore.shared.meetingHotkeyLabel) · \(L("Press to finish"))",
                reopen: false, level: { [weak micRecorder] in micRecorder?.level ?? 0 }
            )
        }
    }

    private func finish() {
        guard let micURL, let systemURL else { return }
        // Diagnostics are only safe to inspect once the IO queue has drained.
        let stoppedTap = systemTap
        stopCapture()
        var systemWasSilent = false
        var systemCaptureFailed = false
        var systemConversionFailed = false
        let micCaptureFailed = micRecorder.writeFailures > 0 || micRecorder.conversionFailures > 0
        if #available(macOS 14.4, *), let tap = stoppedTap as? SystemAudioTap {
            systemWasSilent = !tap.sawNonZeroSample
            systemCaptureFailed = tap.writeFailures > 0 || tap.bufferWrapFailures > 0
            systemConversionFailed = tap.conversionFailures > 0
        }
        let session = liveSession
        let options = recordingOptions
        liveSession = nil
        SoundPlayer.play(.stop)
        let startedAt = self.startedAt ?? Date()
        let recordingStem = self.recordingStem
        let owner = generation
        startProcessing(session: session) { [self] in
            var localSpeechLease = !options.usesCloudSpeech && session != nil
            defer {
                if localSpeechLease { Task { await Transcriber.shared.endMeeting() } }
            }

            var result = await session?.finish() ?? MeetingTranscriptionResult(failedSpeakers: [.me, .them])
            guard generation == owner, !Task.isCancelled else { return }
            if systemConversionFailed { result.failedSpeakers.insert(.them) }
            let needsRecovery = result.needsRecovery
            let diarizationUnavailable = options.usesCloudSpeech && needsRecovery
            if options.usesCloudSpeech && needsRecovery {
                localSpeechLease = true
                await Transcriber.shared.beginMeeting(engine: "whisper")
                guard generation == owner, !Task.isCancelled else { return }
            }
            var recoveryFailed = systemCaptureFailed || micCaptureFailed
            for speaker in [Speaker.me, .them] where result.failedSpeakers.contains(speaker) {
                // A damaged WAV must not replace the useful live prefix.
                if (speaker == .me && micCaptureFailed) || (speaker == .them && systemCaptureFailed) { continue }
                AppModel.shared.meetingStatus = L("Recovering remaining speech from the recording…")
                do {
                    let segments = try await Transcriber.shared.transcribeMeetingFile(
                        fileURL: speaker == .me ? micURL : systemURL,
                        engine: options.usesCloudSpeech ? "whisper" : options.speechEngine
                    )
                    guard generation == owner, !Task.isCancelled else { return }
                    if !result.recover(speaker, from: segments) { recoveryFailed = true }
                } catch {
                    guard generation == owner, !Task.isCancelled else { return }
                    recoveryFailed = true
                    Log.error("Meeting recovery failed for \(speaker.label): \(error.localizedDescription)")
                }
            }
            // The live worker may finish early on overflow. Keep its model
            // lease until recovery is complete, then release it exactly once.
            if localSpeechLease {
                localSpeechLease = false
                await Transcriber.shared.endMeeting()
            }
            guard generation == owner, !Task.isCancelled else { return }
            if needsRecovery { Log.info("Meeting recovery completed; incomplete=\(recoveryFailed)") }
            let mine = result.mine
            let theirs = result.theirs
            AppModel.shared.liveMeetingTurns = result.turns

            if mine.isEmpty && theirs.isEmpty {
                SoundPlayer.play(.error)
                AppModel.shared.meetingStatus = L("No transcript — audio kept for recovery")
                HUD.shared.flash(AppModel.shared.meetingStatus, seconds: 5)
                return
            }

            let turns = TranscriptMerger.merge(mine: mine, theirs: theirs)
            let rawTranscript = TranscriptMerger.markdown(turns: turns)

            var body = rawTranscript
            var structuringFailed = false
            var structuringFailureDescription: String?
            if options.notesEnabled {
                let status = L(options.notesProvider == .gpt5Nano
                    ? "Structuring notes with GPT-5 nano…" : "Structuring notes with local LLM…")
                AppModel.shared.meetingStatus = status
                HUD.shared.update(status)
                let key = options.notesProvider == .gpt5Nano
                    ? try? await AsyncAPIKeyAccess.shared.load(.openAI) : nil
                guard generation == owner, !Task.isCancelled else { return }
                let notes = await MeetingNotesGenerator.shared.generate(
                    markdownTranscript: rawTranscript, provider: options.notesProvider, apiKey: key
                )
                guard generation == owner, !Task.isCancelled else { return }
                if let structured = notes.markdown {
                    body = (notes.isComplete ? "" : "> ⚠️ AI notes are incomplete. Consult the full transcript below.\n\n")
                        + structured + "\n\n---\n\n## Raw transcript\n\n" + rawTranscript
                }
                structuringFailed = !notes.isComplete
                structuringFailureDescription = notes.failure?.localizedDescription
            }

            var notes: [String] = []
            if recoveryFailed {
                notes.append("> ⚠️ Some speech could not be recovered. This transcript may be incomplete; raw audio has been kept in the recordings folder.")
            }
            if systemWasSilent {
                notes.append("> ⚠️ System audio was silent for the whole meeting — check System Settings → Privacy & Security → Screen & System Audio Recording, and pause music players next time.")
            }
            if structuringFailed {
                notes.append("> ⚠️ \(structuringFailureDescription ?? "The selected AI provider could not complete the meeting notes.") The full available transcript is retained below.")
            }
            if diarizationUnavailable {
                notes.append("> ⚠️ A Soniox track required local recovery. Recovered passages identify the audio source only; individual speakers could not be recovered.")
            }
            if options.usesCloudSpeech {
                notes.append("> Speaker numbers are scoped to this meeting and audio source, not real names. Live voice attribution may contain errors or duplicate voices heard through both tracks.")
            }

            let document = """
            # Meeting \(Self.titleFormatter.string(from: startedAt))

            > Recorded with Vocaret. This transcript contains other people's speech; \
            handle it accordingly and delete it when you no longer need it.

            \(notes.isEmpty ? "" : notes.joined(separator: "\n\n") + "\n\n")\(body)
            """

            let outputURL = SettingsStore.shared.meetingsDir
                .appendingPathComponent("\(recordingStem).md")
            do {
                try document.write(to: outputURL, atomically: true, encoding: .utf8)
            } catch {
                SoundPlayer.play(.error)
                AppModel.shared.meetingStatus = L("Could not save transcript — audio kept for recovery")
                HUD.shared.flash(AppModel.shared.meetingStatus, seconds: 4)
                return
            }

            if !SettingsStore.shared.keepRecordings && !recoveryFailed {
                deleteRecordings()
            }

            if recoveryFailed {
                HUD.shared.flash(L("Partial transcript saved — audio kept for recovery"), seconds: 6)
            } else if structuringFailed {
                HUD.shared.flash("Transcript saved without AI structuring (LLM unavailable)", seconds: 5)
            } else if systemWasSilent {
                HUD.shared.flash("Transcript saved — but system audio was silent (check permission)", seconds: 6)
            } else {
                HUD.shared.flash("Meeting transcript saved", seconds: 3)
            }
            AppModel.shared.meetingStatus = recoveryFailed
                ? L("Partial transcript saved — audio kept for recovery")
                : L("Meeting transcript saved")
            AppModel.shared.selectedSection = .meetings
        }
    }

    /// Own the processing lifecycle separately from device capture so a blocked
    /// provider can be cancelled and an older completion cannot close a new job.
    func startProcessing(session: (any MeetingSession)?, operation: @escaping @MainActor () async -> Void) {
        let owner = generation
        finishingSession = session
        state = .processing
        HUD.shared.beginTranscribing(status: L("Finishing meeting…"), hint: L("Esc cancels"))
        AppModel.shared.meetingStatus = L("Completing the last passages")
        registerCancelHotkey()
        processingTask = Task { @MainActor in
            defer {
                if generation == owner {
                    finishingSession = nil
                    processingTask = nil
                    unregisterCancelHotkey()
                    state = .idle
                    AppModel.shared.meetingStartedAt = nil
                    AppModel.shared.refreshMeetings()
                }
            }
            await operation()
        }
    }

    private func registerCancelHotkey() {
        try? HotkeyManager.shared.register(id: HotkeyID.cancel, keyCode: 53, modifiers: 0) { [weak self] in self?.cancel() }
    }

    private func unregisterCancelHotkey() {
        HotkeyManager.shared.unregister(id: HotkeyID.cancel)
    }

    private func cancelLiveSession() {
        guard let session = liveSession else { return }
        liveSession = nil
        let usesCloudSpeech = recordingOptions.usesCloudSpeech
        session.cancel()
        Task {
            _ = await session.finish()
            if !usesCloudSpeech { await Transcriber.shared.endMeeting() }
        }
    }

    private func stopCapture() {
        if #available(macOS 14.4, *), let tap = systemTap as? SystemAudioTap {
            tap.stop()
        }
        systemTap = nil
        micRecorder.stop()
        MediaPauser.shared.resumeIfPaused()
    }

    private func deleteRecordings() {
        for url in [micURL, systemURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        micURL = nil
        systemURL = nil
    }

    static func makeRecordingStem(at date: Date) -> String {
        timestampFormatter.string(from: date) + "-" + UUID().uuidString
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()
}
