import AppKit

/// Menu-bar icon + menu. Reflects dictation/meeting state and exposes the
/// few settings worth toggling (language, AI cleanup, kept recordings).
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let dictation: DictationController
    private let meeting: MeetingController

    private let dictationItem = NSMenuItem()
    private let meetingItem = NSMenuItem()
    private let cancelItem = NSMenuItem()
    private let stateItem = NSMenuItem()
    private let accessibilityWarningItem = NSMenuItem()
    private let copyLastItem = NSMenuItem()

    public init(dictation: DictationController, meeting: MeetingController) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.dictation = dictation
        self.meeting = meeting
        super.init()

        dictation.onStateChange = { [weak self] _ in self?.refresh() }
        meeting.onStateChange = { [weak self] _ in self?.refresh() }

        statusItem.menu = buildMenu()
        refresh()
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        stateItem.isEnabled = false
        menu.addItem(stateItem)

        // Shown only while Accessibility is missing — the one condition that
        // makes dictation look silently broken.
        accessibilityWarningItem.title = "⚠︎ Accessibility not granted — click to fix"
        accessibilityWarningItem.target = self
        accessibilityWarningItem.action = #selector(fixAccessibility)
        menu.addItem(accessibilityWarningItem)

        menu.addItem(.separator())

        // Menu items show the configured global hotkeys as a hint only (the
        // Carbon hotkeys do the actual work system-wide).
        dictationItem.target = self
        dictationItem.action = #selector(toggleDictation)
        menu.addItem(dictationItem)

        meetingItem.target = self
        meetingItem.action = #selector(toggleMeeting)
        menu.addItem(meetingItem)

        cancelItem.title = "Cancel Recording"
        cancelItem.target = self
        cancelItem.action = #selector(cancelRecording)
        menu.addItem(cancelItem)

        menu.addItem(.separator())

        let languageMenu = NSMenu()
        for (title, code) in [("Auto-detect", "auto"), ("Čeština", "cs"), ("English", "en")] {
            let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            languageMenu.addItem(item)
        }
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(makeToggle(title: "Hold Hotkey to Talk (release inserts)", action: #selector(togglePushToTalk)))
        menu.addItem(makeToggle(title: "Show Recording Overlay", action: #selector(toggleShowHUD)))
        menu.addItem(makeToggle(title: "Clean Dictation with AI", action: #selector(toggleCleanDictation)))
        menu.addItem(makeToggle(title: "Structure Meetings with AI", action: #selector(toggleCleanMeetings)))
        menu.addItem(makeToggle(title: "Keep Meeting Audio Files", action: #selector(toggleKeepRecordings)))
        menu.addItem(makeToggle(title: "Start at Login", action: #selector(toggleLoginItem)))

        menu.addItem(.separator())

        copyLastItem.title = "Copy Last Dictation"
        copyLastItem.target = self
        copyLastItem.action = #selector(copyLastTranscript)
        menu.addItem(copyLastItem)

        let openHistory = NSMenuItem(title: "Open Dictation History", action: #selector(openDictationHistory), keyEquivalent: "")
        openHistory.target = self
        menu.addItem(openHistory)

        let openFolder = NSMenuItem(title: "Open Meetings Folder", action: #selector(openMeetingsFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        let permissions = NSMenuItem(title: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Vocaret", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func makeToggle(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - State display

    public func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        let settings = SettingsStore.shared
        let accessibilityOK = Permissions.accessibilityGranted(promptIfNeeded: false)
        accessibilityWarningItem.isHidden = accessibilityOK

        if let last = TranscriptHistory.shared.last {
            let preview = last.text.count > 40 ? String(last.text.prefix(40)) + "…" : last.text
            copyLastItem.title = "Copy Last Dictation — “\(preview)”"
            copyLastItem.isEnabled = true
        } else {
            copyLastItem.title = "Copy Last Dictation"
            copyLastItem.isEnabled = false
        }

        let symbolName: String
        let stateText: String
        switch (dictation.state, meeting.state) {
        case (.recording, _):
            symbolName = "mic.fill"
            stateText = "Recording dictation…"
        case (.transcribing, _):
            symbolName = "waveform"
            stateText = "Transcribing dictation…"
        case (_, .recording):
            symbolName = "record.circle"
            stateText = "Recording meeting…"
        case (_, .processing):
            symbolName = "waveform"
            stateText = "Processing meeting…"
        default:
            symbolName = accessibilityOK ? "mic" : "mic.badge.xmark"
            stateText = accessibilityOK
                ? (settings.pushToTalk
                    ? "Idle — hold \(settings.dictationHotkeyLabel) and speak"
                    : "Idle — \(settings.dictationHotkeyLabel) to dictate")
                : "Idle — needs Accessibility to type text"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Vocaret"
        )
        stateItem.title = stateText

        dictationItem.title = (dictation.state == .recording ? "Stop Dictation & Insert" : "Start Dictation")
            + "  (\(settings.dictationHotkeyLabel))"
        meetingItem.title = (meeting.state == .recording ? "Stop Meeting & Transcribe" : "Start Meeting Transcription")
            + "  (\(settings.meetingHotkeyLabel))"
        cancelItem.isHidden = dictation.state != .recording && meeting.state != .recording

        for item in statusItem.menu?.items ?? [] {
            if let code = item.representedObject as? String {
                item.state = settings.language == code ? .on : .off
            }
            switch item.action {
            case #selector(togglePushToTalk): item.state = settings.pushToTalk ? .on : .off
            case #selector(toggleShowHUD): item.state = settings.showHUD ? .on : .off
            case #selector(toggleCleanDictation): item.state = settings.cleanDictation ? .on : .off
            case #selector(toggleCleanMeetings): item.state = settings.cleanMeetings ? .on : .off
            case #selector(toggleKeepRecordings): item.state = settings.keepRecordings ? .on : .off
            case #selector(toggleLoginItem):
                item.state = LoginItem.isEnabled ? .on : .off
                item.isEnabled = LoginItem.isBundled
            default: break
            }
            if let submenu = item.submenu {
                for subitem in submenu.items {
                    if let code = subitem.representedObject as? String {
                        subitem.state = settings.language == code ? .on : .off
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleDictation() { dictation.toggle() }
    @objc private func toggleMeeting() { meeting.toggle() }

    @objc private func cancelRecording() {
        dictation.cancel()
        meeting.cancel()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String {
            SettingsStore.shared.language = code
            refresh()
        }
    }

    @objc private func togglePushToTalk() {
        SettingsStore.shared.pushToTalk.toggle()
        refresh()
    }

    @objc private func toggleShowHUD() {
        SettingsStore.shared.showHUD.toggle()
        if !SettingsStore.shared.showHUD { HUD.shared.hide() }
        refresh()
    }

    @objc private func toggleCleanDictation() {
        SettingsStore.shared.cleanDictation.toggle()
        refresh()
    }

    @objc private func toggleCleanMeetings() {
        SettingsStore.shared.cleanMeetings.toggle()
        refresh()
    }

    @objc private func toggleKeepRecordings() {
        SettingsStore.shared.keepRecordings.toggle()
        refresh()
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        refresh()
    }

    @objc private func copyLastTranscript() {
        guard let entry = TranscriptHistory.shared.last else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        HUD.shared.flash("Last dictation copied — press ⌘V", seconds: 3)
    }

    @objc private func openDictationHistory() {
        let url = TranscriptHistory.shared.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            HUD.shared.flash("No dictation history yet", seconds: 3)
        }
    }

    @objc private func fixAccessibility() {
        _ = Permissions.accessibilityGranted(promptIfNeeded: true)
        Permissions.openAccessibilitySettings()
    }

    @objc private func openMeetingsFolder() {
        NSWorkspace.shared.open(SettingsStore.shared.meetingsDir)
    }

    @objc private func checkPermissions() {
        let microphone: String
        switch Permissions.microphoneStatus {
        case .authorized: microphone = "granted"
        case .notDetermined: microphone = "not requested yet (starts with first recording)"
        default: microphone = "DENIED — enable in System Settings → Privacy → Microphone"
        }
        let accessibility = Permissions.accessibilityGranted(promptIfNeeded: false)
            ? "granted"
            : "NOT granted — needed to auto-paste; System Settings → Privacy → Accessibility"

        let alert = NSAlert()
        alert.messageText = "Vocaret Permissions"
        alert.informativeText = """
        Microphone: \(microphone)
        Accessibility (auto-paste): \(accessibility)
        System Audio Recording: macOS asks the first time you start a meeting transcription.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Accessibility Settings")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }
}
