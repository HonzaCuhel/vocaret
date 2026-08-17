import AppKit

/// Hotkey → record → transcribe → (optionally clean) → paste at caret.
@MainActor
public final class DictationController {
    public enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    public var onStateChange: ((State) -> Void)?

    private let recorder = MicRecorder()
    /// Guards the async gap in start() (permission prompt) against a second
    /// hotkey press starting a second recording.
    private var isStarting = false
    private var releasedWhileStarting = false
    /// The transcribe/clean/paste job, kept so Esc can abort a slow cleanup.
    private var job: Task<Void, Never>?

    public init() {}

    /// Shorter than this and the press counts as a tap (toggle mode) rather
    /// than a hold, so a quick tap-speak-tap still works.
    private static let holdThreshold: TimeInterval = 0.35
    private var pressStarted: Date?

    /// Hotkey went down.
    public func toggle() {
        switch state {
        case .idle:
            guard !isStarting else { return }
            pressStarted = Date()
            start()
        case .recording:
            pressStarted = nil
            finish()
        case .transcribing:
            break // ignore presses while a transcription is in flight; Esc cancels
        }
    }

    /// Hotkey came back up. In push-to-talk mode a held key ends the recording
    /// and inserts immediately; a quick tap leaves it recording until the next
    /// press.
    public func hotkeyReleased() {
        guard SettingsStore.shared.pushToTalk else { return }
        // Released before the mic finished starting (permission check, engine
        // start): remember it so start() can honour it instead of recording on.
        if isStarting {
            releasedWhileStarting = true
            return
        }
        guard state == .recording, let pressStarted else { return }
        guard Date().timeIntervalSince(pressStarted) >= Self.holdThreshold else { return }
        self.pressStarted = nil
        finish()
    }

    public func cancel() {
        switch state {
        case .recording:
            _ = recorder.stop()
            unregisterCancelHotkey()
            SoundPlayer.play(.stop)
            HUD.shared.hide()
            state = .idle
        case .transcribing:
            job?.cancel()
            job = nil
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
        _ = recorder.stop()
        state = .idle
    }

    private func start() {
        isStarting = true
        releasedWhileStarting = false
        Task { @MainActor in
            defer { isStarting = false }
            guard await Permissions.requestMicrophone() else {
                HUD.shared.flash("Microphone access denied — enable it in System Settings")
                Permissions.openMicrophoneSettings()
                return
            }
            guard state == .idle else { return }
            do {
                try recorder.startInMemory()
            } catch {
                SoundPlayer.play(.error)
                HUD.shared.flash("Could not start recording: \(error.localizedDescription)")
                return
            }
            recorder.onInterrupted = { [weak self] error in
                self?.handleInterruption(error)
            }
            SoundPlayer.play(.start)
            state = .recording
            let hotkey = SettingsStore.shared.dictationHotkeyLabel
            let heldDuration = pressStarted.map { Date().timeIntervalSince($0) } ?? 0
            let holding = SettingsStore.shared.pushToTalk && !releasedWhileStarting
            HUD.shared.show(
                holding
                    ? "● Recording — release \(hotkey) to insert, Esc to cancel"
                    : "● Recording — \(hotkey) to insert, Esc to cancel"
            )
            registerCancelHotkey()

            // The key was already let go while we were starting up.
            if releasedWhileStarting, SettingsStore.shared.pushToTalk, heldDuration >= Self.holdThreshold {
                releasedWhileStarting = false
                pressStarted = nil
                finish()
            }
        }
    }

    private func handleInterruption(_ error: Error?) {
        guard state == .recording else { return }
        Log.warn("Dictation recording interrupted: \(error?.localizedDescription ?? "audio device changed")")
        // Keep what we have; the user can stop normally. Just tell them.
        HUD.shared.update("● Recording (audio device changed) — press the hotkey to insert")
    }

    private func finish() {
        let samples = recorder.stop()
        SoundPlayer.play(.stop)
        state = .transcribing
        HUD.shared.update("Transcribing… (Esc to cancel)")
        // Remember where the text should go — the user may switch apps while
        // we transcribe, and we must not paste into an unrelated window.
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let targetName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the active app"

        job = Task { @MainActor in
            defer {
                unregisterCancelHotkey()
                if state == .transcribing { state = .idle }
                job = nil
            }
            do {
                var text = try await Transcriber.shared.transcribe(samples: samples)
                try Task.checkCancellation()
                if text.isEmpty {
                    HUD.shared.flash("Nothing recognized")
                    return
                }
                if SettingsStore.shared.cleanDictation {
                    HUD.shared.update("Cleaning up… (Esc to cancel)")
                    text = await LLMCleaner.shared.cleanDictation(text)
                    try Task.checkCancellation()
                }
                // Record BEFORE inserting: whatever happens next, the
                // transcript is retrievable from the menu (Copy Last Dictation).
                TranscriptHistory.shared.record(text)

                switch await TextInserter.insert(text, targetPID: targetPID) {
                case .insertedViaAccessibility, .pastedViaClipboard:
                    HUD.shared.hide()
                case .noAccessibility:
                    HUD.shared.flash("Copied to clipboard — press ⌘V. Grant Accessibility for auto-typing.", seconds: 6)
                    Permissions.openAccessibilitySettings()
                case .targetChanged(let now):
                    HUD.shared.flash("You switched from \(targetName) to \(now) — transcript copied, press ⌘V", seconds: 6)
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

    private func registerCancelHotkey() {
        try? HotkeyManager.shared.register(id: HotkeyID.cancel, keyCode: 53, modifiers: 0) { [weak self] in
            self?.cancel()
        }
    }

    private func unregisterCancelHotkey() {
        HotkeyManager.shared.unregister(id: HotkeyID.cancel)
    }
}
