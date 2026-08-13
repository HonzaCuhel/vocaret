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

    public init() {}

    public func toggle() {
        switch state {
        case .idle:
            start()
        case .recording:
            finish()
        case .transcribing:
            break // ignore presses while a transcription is in flight
        }
    }

    public func cancel() {
        guard state == .recording else { return }
        _ = recorder.stop()
        unregisterCancelHotkey()
        SoundPlayer.play(.stop)
        HUD.shared.hide()
        state = .idle
    }

    private func start() {
        Task { @MainActor in
            guard await Permissions.requestMicrophone() else {
                HUD.shared.flash("Microphone access denied — enable it in System Settings")
                Permissions.openMicrophoneSettings()
                return
            }
            do {
                try recorder.startInMemory()
            } catch {
                SoundPlayer.play(.error)
                HUD.shared.flash("Could not start recording: \(error.localizedDescription)")
                return
            }
            SoundPlayer.play(.start)
            state = .recording
            HUD.shared.show("● Recording — ⌃⌥Space to insert, Esc to cancel")
            registerCancelHotkey()
        }
    }

    private func finish() {
        let samples = recorder.stop()
        unregisterCancelHotkey()
        SoundPlayer.play(.stop)
        state = .transcribing
        HUD.shared.update("Transcribing…")

        Task { @MainActor in
            defer { state = .idle }
            do {
                var text = try await Transcriber.shared.transcribe(samples: samples)
                if text.isEmpty {
                    HUD.shared.flash("Nothing recognized")
                    return
                }
                if SettingsStore.shared.cleanDictation {
                    HUD.shared.update("Cleaning up…")
                    text = await LLMCleaner.shared.cleanDictation(text)
                }
                let pasted = TextInserter.insert(text)
                if pasted {
                    HUD.shared.hide()
                } else {
                    HUD.shared.flash("Copied — press ⌘V to paste (grant Accessibility for auto-paste)", seconds: 4)
                }
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
