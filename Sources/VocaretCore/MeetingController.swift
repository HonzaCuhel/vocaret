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
        didSet { onStateChange?(state) }
    }

    public var onStateChange: ((State) -> Void)?

    private let micRecorder = MicRecorder()
    private var systemTap: Any? // SystemAudioTap, typed loosely for the @available gate
    private var micURL: URL?
    private var systemURL: URL?
    private var startedAt: Date?
    private var isStarting = false

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
        stopCapture()
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
        stopCapture()
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

            let tap = SystemAudioTap()
            do {
                // Tap first: its start triggers the one-time system-audio permission.
                try tap.start(writingTo: systemURL)
                try micRecorder.startToFile(url: micURL)
            } catch {
                tap.stop()
                micRecorder.stop()
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
            SoundPlayer.play(.start)
            state = .recording
            HUD.shared.show("● Recording meeting — \(SettingsStore.shared.meetingHotkeyLabel) to finish")
        }
    }

    private func finish() {
        guard let micURL, let systemURL else { return }
        var systemWasSilent = false
        if #available(macOS 14.4, *), let tap = systemTap as? SystemAudioTap {
            systemWasSilent = !tap.sawNonZeroSample
        }
        stopCapture()
        SoundPlayer.play(.stop)
        state = .processing
        HUD.shared.update("Transcribing meeting… this can take a few minutes")

        let startedAt = self.startedAt ?? Date()
        Task { @MainActor in
            defer { state = .idle }

            // Transcribe sequentially — the Whisper actor serializes anyway,
            // and this keeps peak memory to a single decode at a time.
            let mine = (try? await Transcriber.shared.transcribe(fileURL: micURL)) ?? []
            let theirs = (try? await Transcriber.shared.transcribe(fileURL: systemURL)) ?? []

            if mine.isEmpty && theirs.isEmpty {
                SoundPlayer.play(.error)
                HUD.shared.flash("Meeting transcription produced no text", seconds: 4)
                return
            }

            let turns = TranscriptMerger.merge(mine: mine, theirs: theirs)
            let rawTranscript = TranscriptMerger.markdown(turns: turns)

            var body = rawTranscript
            var structuringFailed = false
            if SettingsStore.shared.cleanMeetings {
                HUD.shared.update("Structuring notes with local LLM…")
                if let structured = await LLMCleaner.shared.structureMeeting(markdownTranscript: rawTranscript) {
                    body = structured + "\n\n---\n\n## Raw transcript\n\n" + rawTranscript
                } else {
                    structuringFailed = true
                }
            }

            var notes: [String] = []
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
                HUD.shared.flash("Could not save transcript: \(error.localizedDescription)", seconds: 4)
                return
            }

            if !SettingsStore.shared.keepRecordings {
                deleteRecordings()
            }

            if structuringFailed {
                HUD.shared.flash("Transcript saved without AI structuring (LLM unavailable)", seconds: 5)
            } else if systemWasSilent {
                HUD.shared.flash("Transcript saved — but system audio was silent (check permission)", seconds: 6)
            } else {
                HUD.shared.flash("Meeting transcript saved", seconds: 3)
            }
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }

    private func stopCapture() {
        if #available(macOS 14.4, *), let tap = systemTap as? SystemAudioTap {
            tap.stop()
        }
        systemTap = nil
        micRecorder.stop()
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
