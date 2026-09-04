import AppKit

/// Records both sides of a meeting (mic = Me, system audio = Them), then
/// transcribes, merges, optionally structures with the local LLM, and saves
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
    private var isStarting = false
    private var liveSession: MeetingTranscriptionSession?
    private var generation = 0
    private var recordingEngine = "whisper"

    public init() {}

    public func toggle() {
        switch state {
        case .idle:
            guard !isStarting else { return }
            start()
        case .recording:
            finish()
        case .processing:
            break
        }
    }

    public func cancel() {
        guard state == .recording else { return }
        generation += 1
        stopCapture()
        cancelLiveSession()
        AppModel.shared.liveMeetingTurns = []
        AppModel.shared.meetingStartedAt = nil
        deleteRecordings()
        SoundPlayer.play(.stop)
        HUD.shared.hide()
        state = .idle
    }

    /// Called on app quit while recording: closes both WAV writers so the
    /// headers are finalized. Files are kept and can be transcribed later with
    /// `Vocaret --transcribe <file>`.
    public func stopForTermination() {
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

        Vocaret keeps the transcript on this Mac and deletes the raw audio unless \
        you turn that off.
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
            HUD.shared.flash("Meeting capture needs macOS 14.4 or newer")
            return
        }
        guard consentAcknowledged() else { return }
        isStarting = true
        Task { @MainActor in
            defer { isStarting = false }
            guard await Permissions.requestMicrophone() else {
                HUD.shared.flash("Microphone access denied — enable it in System Settings")
                Permissions.openMicrophoneSettings()
                return
            }
            guard state == .idle else { return }

            let timestamp = Self.timestampFormatter.string(from: Date())
            let recordingsDir = SettingsStore.shared.recordingsDir
            let micURL = recordingsDir.appendingPathComponent("\(timestamp)-mic.wav")
            let systemURL = recordingsDir.appendingPathComponent("\(timestamp)-system.wav")

            generation += 1
            let owner = generation
            recordingEngine = SettingsStore.shared.asrEngine == "parakeet" ? "parakeet" : "whisper"
            let engine = recordingEngine
            AppModel.shared.liveMeetingTurns = []
            AppModel.shared.meetingStatus = L("Preparing local speech model…")
            let session = MeetingTranscriptionSession(
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
                onUpdate: { result in
                    await MainActor.run {
                        guard self.generation == owner, self.state != .idle else { return }
                        AppModel.shared.liveMeetingTurns = result.turns
                        if result.needsRecovery {
                            AppModel.shared.meetingStatus = L("Recording safely — remaining speech will be recovered after finishing")
                        }
                        if let turn = result.turns.last {
                            HUD.shared.updatePartial("\(L(turn.speaker.label)): \(turn.text)")
                        }
                    }
                }
            )
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
                generation += 1
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
            self.startedAt = Date()
            AppModel.shared.meetingStartedAt = self.startedAt
            SoundPlayer.play(.start)
            state = .recording
            MediaPauser.shared.pauseIfPlaying()
            if SettingsStore.shared.cleanMeetings { LLMCleaner.shared.warmUp() }
            HUD.shared.beginRecording(
                status: L("Live meeting · On this Mac"),
                hint: "\(SettingsStore.shared.meetingHotkeyLabel) · \(L("Press to finish"))",
                level: { [weak micRecorder] in micRecorder?.level ?? 0 }
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
        liveSession = nil
        SoundPlayer.play(.stop)
        state = .processing
        HUD.shared.beginTranscribing(
            status: L("Finishing meeting…"),
            hint: L("Completing the last passages")
        )

        AppModel.shared.meetingStatus = L("Completing the last passages")
        let startedAt = self.startedAt ?? Date()
        Task { @MainActor in
            defer {
                state = .idle
                AppModel.shared.meetingStartedAt = nil
                AppModel.shared.refreshMeetings()
            }

            var result = await session?.finish() ?? MeetingTranscriptionResult(failedSpeakers: [.me, .them])
            if systemConversionFailed { result.failedSpeakers.insert(.them) }
            let needsRecovery = result.needsRecovery
            var recoveryFailed = systemCaptureFailed || micCaptureFailed
            for speaker in [Speaker.me, .them] where result.failedSpeakers.contains(speaker) {
                // A damaged WAV must not replace the useful live prefix.
                if (speaker == .me && micCaptureFailed) || (speaker == .them && systemCaptureFailed) { continue }
                AppModel.shared.meetingStatus = L("Recovering remaining speech from the recording…")
                do {
                    let segments = try await Transcriber.shared.transcribe(fileURL: speaker == .me ? micURL : systemURL)
                    result.recover(speaker, from: segments)
                } catch {
                    recoveryFailed = true
                    Log.error("Meeting recovery failed for \(speaker.label): \(error.localizedDescription)")
                }
            }
            // The live worker may finish early on overflow. Keep its model
            // lease until recovery is complete, then release it exactly once.
            if session != nil { await Transcriber.shared.endMeeting() }
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
            if SettingsStore.shared.cleanMeetings {
                AppModel.shared.meetingStatus = L("Structuring notes with local LLM…")
                HUD.shared.update(L("Structuring notes with local LLM…"))
                if let structured = await LLMCleaner.shared.structureMeeting(markdownTranscript: rawTranscript) {
                    body = structured + "\n\n---\n\n## Raw transcript\n\n" + rawTranscript
                } else {
                    structuringFailed = true
                }
            }

            var notes: [String] = []
            if recoveryFailed {
                notes.append("> ⚠️ Some speech could not be recovered. This transcript may be incomplete; raw audio has been kept in the recordings folder.")
            }
            if systemWasSilent {
                notes.append("> ⚠️ System audio was silent for the whole meeting — check System Settings → Privacy & Security → Screen & System Audio Recording, and pause music players next time.")
            }
            if structuringFailed {
                notes.append("> ⚠️ AI structuring failed (llama-server missing or error) — raw transcript only.")
            }

            let document = """
            # Meeting \(Self.titleFormatter.string(from: startedAt))

            > Recorded with Vocaret. This transcript contains other people's speech; \
            handle it accordingly and delete it when you no longer need it.

            \(notes.isEmpty ? "" : notes.joined(separator: "\n\n") + "\n\n")\(body)
            """

            let outputURL = SettingsStore.shared.meetingsDir
                .appendingPathComponent("\(Self.timestampFormatter.string(from: startedAt)).md")
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

    private func cancelLiveSession() {
        guard let session = liveSession else { return }
        liveSession = nil
        session.cancel()
        Task {
            _ = await session.finish()
            await Transcriber.shared.endMeeting()
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
