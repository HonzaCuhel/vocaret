import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private let dictation = DictationController()
    private let meeting = MeetingController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(dictation: dictation, meeting: meeting)
        registerHotkeys()
        LLMCleaner.shared.reapStaleServer()
        warnIfAccessibilityMissing()

        // Preload Whisper so the first dictation is instant. First launch
        // downloads the model (~632 MB), so surface that in the HUD.
        Task { @MainActor in
            let modelPresent = FileManager.default.fileExists(
                atPath: SettingsStore.shared.modelsDir.appendingPathComponent("models").path
            )
            if !modelPresent {
                HUD.shared.flash("Downloading Whisper model (one-time, ~630 MB)…", seconds: 6)
            }
            await Transcriber.shared.preload()
            let ready = await Transcriber.shared.isReady
            // Don't talk over an active recording the user already started.
            guard dictation.state == .idle, meeting.state == .idle else { return }
            if ready {
                HUD.shared.flash("JustSayIt ready — press \(SettingsStore.shared.dictationHotkeyLabel) and speak", seconds: 3)
            } else {
                HUD.shared.flash("Whisper model failed to load — check the log", seconds: 5)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Finalize any WAV being written and free the LLM server.
        meeting.stopForTermination()
        dictation.stopForTermination()
        LLMCleaner.shared.terminateServerNow()
    }

    /// Without Accessibility the app can only put text on the clipboard, which
    /// looks exactly like "dictation is broken". Say so up front, once.
    private func warnIfAccessibilityMissing() {
        guard !Permissions.accessibilityGranted(promptIfNeeded: false) else { return }
        Log.warn("Accessibility not granted — auto-paste unavailable")
        let alert = NSAlert()
        alert.messageText = "JustSayIt needs Accessibility permission"
        alert.informativeText = """
        Without it, dictated text can only be copied to the clipboard instead of being typed \
        where your cursor is.

        Enable JustSayIt in System Settings → Privacy & Security → Accessibility.

        (If it is already listed, switch it off and on again — a rebuilt app counts as a new app.)
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
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
