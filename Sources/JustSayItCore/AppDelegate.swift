import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private let dictation = DictationController()
    private let meeting = MeetingController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(dictation: dictation, meeting: meeting)
        registerHotkeys()

        // Preload Whisper so the first dictation is instant. First launch
        // downloads the model (~632 MB), so surface that in the HUD.
        Task { @MainActor in
            if !FileManager.default.fileExists(
                atPath: SettingsStore.shared.modelsDir
                    .appendingPathComponent("models").path
            ) {
                HUD.shared.flash("Downloading Whisper model (one-time, ~630 MB)…", seconds: 6)
            }
            await Transcriber.shared.preload()
            let ready = await Transcriber.shared.isReady
            if ready {
                HUD.shared.flash("JustSayIt ready — press ⌃⌥Space and speak", seconds: 3)
            } else {
                HUD.shared.flash("Whisper model failed to load — check the log", seconds: 5)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        LLMCleaner.shared.terminateServerNow()
    }

    private func registerHotkeys() {
        let settings = SettingsStore.shared
        do {
            try HotkeyManager.shared.register(
                id: HotkeyID.dictation,
                keyCode: settings.dictationKeyCode,
                modifiers: settings.dictationModifiers
            ) { [weak self] in
                self?.dictation.toggle()
            }
            try HotkeyManager.shared.register(
                id: HotkeyID.meeting,
                keyCode: settings.meetingKeyCode,
                modifiers: settings.meetingModifiers
            ) { [weak self] in
                self?.meeting.toggle()
            }
        } catch {
            HUD.shared.flash("Hotkey registration failed: \(error.localizedDescription)", seconds: 5)
            Log.error("Hotkey registration failed: \(error)")
        }
    }
}
