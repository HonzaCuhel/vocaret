import AppKit

/// Records both sides of a meeting (mic = Me, system audio = Them), then
/// transcribes, merges, optionally structures with the local LLM, and saves
/// a Markdown file to ~/Documents/JustSayIt/Meetings.
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

    public init() {}

    public func toggle() {
        switch state {
        case .idle:
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

    private func start() {
        guard #available(macOS 14.4, *) else {
            HUD.shared.flash("Meeting capture needs macOS 14.4 or newer")
            return
        }
        Task { @MainActor in
            guard await Permissions.requestMicrophone() else {
                HUD.shared.flash("Microphone access denied — enable it in System Settings")
                Permissions.openMicrophoneSettings()
                return
            }

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
                HUD.shared.flash("Could not start meeting capture: \(error.localizedDescription)", seconds: 4)
                Log.error("Meeting capture failed to start: \(error)")
                return
            }

            self.systemTap = tap
            self.micURL = micURL
            self.systemURL = systemURL
            self.startedAt = Date()
            SoundPlayer.play(.start)
            state = .recording
            HUD.shared.show("● Recording meeting — ⌃⌥M to finish")
        }
    }

    private func finish() {
        guard let micURL, let systemURL else { return }
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
            if SettingsStore.shared.cleanMeetings {
                HUD.shared.update("Structuring notes with local LLM…")
                let structured = await LLMCleaner.shared.structureMeeting(markdownTranscript: rawTranscript)
                if structured != rawTranscript {
                    body = structured + "\n\n---\n\n## Raw transcript\n\n" + rawTranscript
                }
            }

            let document = """
            # Meeting \(Self.titleFormatter.string(from: startedAt))

            \(body)
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

            HUD.shared.flash("Meeting transcript saved", seconds: 3)
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
