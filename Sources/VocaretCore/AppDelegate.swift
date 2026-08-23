import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private let dictation = DictationController()
    private let meeting = MeetingController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.apply(SettingsStore.shared.appearance)
        MainWindowController.installMainMenu()
        statusController = StatusItemController(dictation: dictation, meeting: meeting)
        registerHotkeys()
        LLMCleaner.shared.reapStaleServer()
        MediaPauser.shared.primePermissions()
        registerDebugIPC()

        // First launch: open the window so a new user sees what this is and
        // where the shortcut lives, instead of an unexplained menu-bar glyph.
        if !SettingsStore.shared.hasShownWindow {
            SettingsStore.shared.hasShownWindow = true
            MainWindowController.shared.show()
        }

        // Preload only the selected local engine. Soniox uses no local ASR RAM,
        // and opting out of a resident model defers loading until first use.
        Task { @MainActor in
            let settings = SettingsStore.shared
            let target = ModelLifecyclePolicy.preloadTarget(engine: settings.asrEngine)
            if target != .none, settings.keepModelLoaded {
                HUD.shared.flash("Preparing the selected speech model…", seconds: 4)
                await Transcriber.shared.preload()
            }
            let ready: Bool
            if target == .none {
                ready = await Transcriber.shared.isReady
            } else if !settings.keepModelLoaded {
                ready = true
            } else {
                ready = await Transcriber.shared.isReady
            }
            // Don't talk over an active recording the user already started.
            guard dictation.state == .idle, meeting.state == .idle else { return }
            if ready {
                HUD.shared.flash("Vocaret ready — press \(SettingsStore.shared.dictationHotkeyLabel) and speak", seconds: 3)
            } else if target == .none {
                HUD.shared.flash("Add your Soniox API key in Settings to use live transcription", seconds: 5)
            } else {
                HUD.shared.flash("Speech model failed to load — check the log", seconds: 5)
            }
            // Only now (never before the model is up — a modal alert would
            // stall the launch path) nag about the permission that makes
            // dictation actually appear where the cursor is.
            warnIfAccessibilityMissing()
        }
    }

    /// Debug-only (defaults write com.jancuhel.vocaret debugIPC -bool YES):
    /// lets a local test drive dictation exactly like the hotkey would.
    /// Off by default — anyone local can post distributed notifications.
    private func registerDebugIPC() {
        guard UserDefaults.standard.bool(forKey: "debugIPC") else { return }
        Log.warn("debugIPC enabled — dictation can be toggled by local processes")
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.jancuhel.vocaret.debug.toggleDictation"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dictation.toggle() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.jancuhel.vocaret.debug.mediaPlay"), object: nil, queue: nil
        ) { _ in
            for player in MediaPauser.shared.runningPlayers() { MediaPauser.shared.send("play", to: player) }
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    @objc public func openMainWindowFromMenu(_ sender: Any?) {
        MainWindowController.shared.show()
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
        alert.messageText = "Vocaret needs Accessibility permission"
        alert.informativeText = """
        Without it, dictated text can only be copied to the clipboard instead of being typed \
        where your cursor is.

        Enable Vocaret in System Settings → Privacy & Security → Accessibility.

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
                modifiers: settings.dictationModifiers,
                handler: { [weak self] in self?.dictation.toggle() },
                onRelease: { [weak self] in self?.dictation.hotkeyReleased() }
            )
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
