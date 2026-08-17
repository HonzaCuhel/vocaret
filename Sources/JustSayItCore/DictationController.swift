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
    /// The transcribe/clean/paste job, kept so Esc can abort a slow cleanup.
    private var job: Task<Void, Never>?

    public init() {}

    public func toggle() {
        switch state {
        case .idle:
            guard !isStarting else { return }
            start()
        case .recording:
            finish()
        case .transcribing:
            break // ignore presses while a transcription is in flight; Esc cancels
        }
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
            HUD.shared.show("● Recording — \(hotkey) to insert, Esc to cancel")
            registerCancelHotkey()
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
                let pasted = await TextInserter.insert(text)
                if pasted {
                    HUD.shared.hide()
                } else {
                    // Not a silent failure: say what happened and how to fix it.
                    HUD.shared.flash("Copied to clipboard — press ⌘V. Grant Accessibility for auto-typing.", seconds: 6)
                    Permissions.openAccessibilitySettings()
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
