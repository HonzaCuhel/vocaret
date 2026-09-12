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
        NotificationCenter.default.addObserver(forName: .vocaretUILanguageChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem.menu = self.buildMenu()
                self.refresh()
            }
        }
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        // The long-lived items below are reused across rebuilds (interface
        // language change). AppKit throws if an item is added while it still
        // belongs to the previous menu — and an exception thrown from a
        // MainActor task wedges the main dispatch queue for good.
        for item in [stateItem, accessibilityWarningItem, dictationItem, meetingItem, cancelItem, copyLastItem] {
            item.menu?.removeItem(item)
        }

        let menu = NSMenu()
        menu.delegate = self

        stateItem.isEnabled = false
        menu.addItem(stateItem)

        let openWindow = NSMenuItem(title: L("Open Vocaret…"), action: #selector(openMainWindow), keyEquivalent: "o")
        openWindow.keyEquivalentModifierMask = [.command]
        openWindow.target = self
        menu.addItem(openWindow)

        let companion = NSMenuItem(title: L("Show floating panel"), action: #selector(showCompanion), keyEquivalent: "")
        companion.target = self
        menu.addItem(companion)

        // Shown only while Accessibility is missing — the one condition that
        // makes dictation look silently broken.
        accessibilityWarningItem.title = L("⚠︎ Accessibility not granted — click to fix")
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

        cancelItem.title = L("Cancel Recording")
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
        let languageItem = NSMenuItem(title: L("Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let appearanceMenu = NSMenu()
        for option in Appearance.options {
            let item = NSMenuItem(title: option.title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "appearance:" + option.id
            appearanceMenu.addItem(item)
        }
        let appearanceItem = NSMenuItem(title: L("Appearance"), action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        menu.addItem(makeToggle(title: L("Hold Hotkey to Talk (release inserts)"), action: #selector(togglePushToTalk)))
        menu.addItem(makeToggle(title: L("Show Recording Overlay"), action: #selector(toggleShowHUD)))
        menu.addItem(makeToggle(title: L("Pause Music While Recording"), action: #selector(togglePauseMedia)))
        menu.addItem(makeToggle(title: L("Clean Dictation with AI"), action: #selector(toggleCleanDictation)))
        menu.addItem(makeToggle(title: L("Structure Meetings with AI"), action: #selector(toggleCleanMeetings)))
        menu.addItem(makeToggle(title: L("Keep Meeting Audio Files"), action: #selector(toggleKeepRecordings)))
        menu.addItem(makeToggle(title: L("Start at Login"), action: #selector(toggleLoginItem)))

        menu.addItem(.separator())

        let addWord = NSMenuItem(title: L("Add Word to Vocabulary…"), action: #selector(addVocabularyWord), keyEquivalent: "")
        addWord.target = self
        menu.addItem(addWord)

        let openVocabulary = NSMenuItem(title: L("Edit Vocabulary…"), action: #selector(openVocabularyFile), keyEquivalent: "")
        openVocabulary.target = self
        menu.addItem(openVocabulary)

        menu.addItem(.separator())

        copyLastItem.title = L("Copy Last Dictation")
        copyLastItem.target = self
        copyLastItem.action = #selector(copyLastTranscript)
        menu.addItem(copyLastItem)

        let openHistory = NSMenuItem(title: L("Open Dictation History"), action: #selector(openDictationHistory), keyEquivalent: "")
        openHistory.target = self
        menu.addItem(openHistory)

        let openFolder = NSMenuItem(title: L("Open Meetings Folder"), action: #selector(openMeetingsFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        let permissions = NSMenuItem(title: L("Check Permissions…"), action: #selector(checkPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit Vocaret"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            copyLastItem.title = L("Copy Last Dictation")
            copyLastItem.isEnabled = false
        }

        let symbolName: String
        let stateText: String
        switch (dictation.state, meeting.state) {
        case (.recording, _):
            symbolName = "mic.fill"
            stateText = L("Recording dictation…")
        case (.transcribing, _):
            symbolName = "waveform"
            stateText = L("Transcribing dictation…")
        case (_, .recording):
            symbolName = "record.circle"
            stateText = L("Recording meeting…")
        case (_, .processing):
            symbolName = "waveform"
            stateText = L("Processing meeting…")
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

        dictationItem.title = (dictation.state == .recording ? L("Stop Dictation & Insert") : L("Start Dictation"))
            + "  (\(settings.dictationHotkeyLabel))"
        meetingItem.title = (meeting.state == .recording ? L("Stop Meeting & Transcribe") : L("Start Meeting Transcription"))
            + "  (\(settings.meetingHotkeyLabel))"
        cancelItem.isHidden = dictation.state != .recording && meeting.state != .recording

        for item in statusItem.menu?.items ?? [] {
            if let code = item.representedObject as? String {
                item.state = settings.language == code ? .on : .off
            }
            switch item.action {
            case #selector(togglePushToTalk): item.state = settings.pushToTalk ? .on : .off
            case #selector(toggleShowHUD): item.state = settings.showHUD ? .on : .off
            case #selector(togglePauseMedia): item.state = settings.pauseMediaWhileRecording ? .on : .off
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
                        if code.hasPrefix("appearance:") {
                            subitem.state = settings.appearance == String(code.dropFirst("appearance:".count)) ? .on : .off
                        } else {
                            subitem.state = settings.language == code ? .on : .off
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func showCompanion() { HUD.shared.showCompanion() }

    @objc private func toggleDictation() { dictation.toggle() }
    @objc private func toggleMeeting() { meeting.toggle() }

    @objc private func cancelRecording() {
        dictation.cancel()
        meeting.cancel()
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, raw.hasPrefix("appearance:") {
            Appearance.set(String(raw.dropFirst("appearance:".count)))
            refresh()
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String, !code.hasPrefix("appearance:") {
            SettingsStore.shared.language = code
            refresh()
        }
    }

    @objc private func togglePushToTalk() {
        SettingsStore.shared.pushToTalk.toggle()
        refresh()
    }

    @objc private func togglePauseMedia() {
        SettingsStore.shared.pauseMediaWhileRecording.toggle()
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

    @objc private func addVocabularyWord() {
        let alert = NSAlert()
        alert.messageText = "Add a word to your vocabulary"
        alert.informativeText = """
        Vocaret will always spell it this way — product names, jargon, names of \
        people. Type it exactly as you want it written.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. WhisperKit"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        Vocabulary.shared.addTerm(word)
        HUD.shared.flash("“\(word)” added to your vocabulary", seconds: 3)
    }

    @objc private func openVocabularyFile() {
        guard let url = Vocabulary.shared.vocabularyFileURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            Vocabulary.shared.save()
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLastTranscript() {
        guard DictationFinalizer.copyLast(from: .shared, write: { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }) else { return }
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

    @objc private func openMainWindow() {
        MainWindowController.shared.show()
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
