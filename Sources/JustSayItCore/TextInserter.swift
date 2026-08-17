import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What happened to a transcript. The caller must tell the user — a transcript
/// that silently goes nowhere is the worst failure this app can have.
public enum InsertOutcome: Equatable {
    /// Written straight into the focused field via the Accessibility API.
    case insertedViaAccessibility
    /// Put on the clipboard and ⌘V synthesized into the target app.
    case pastedViaClipboard
    /// Accessibility permission missing — text is on the clipboard only.
    case noAccessibility
    /// The user switched apps between speaking and the transcript being ready;
    /// text is on the clipboard rather than pasted into the wrong window.
    case targetChanged(String)

    public var didInsert: Bool {
        self == .insertedViaAccessibility || self == .pastedViaClipboard
    }
}

/// Inserts text at the current keyboard caret of the target app, Wispr-Flow
/// style. Prefers the Accessibility API (no clipboard involvement); falls back
/// to clipboard + synthesized ⌘V for apps without an AX text element.
@MainActor
public enum TextInserter {

    /// - Parameter targetPID: the app that was frontmost when recording stopped.
    ///   Insertion is refused if the user has since switched apps, so a
    ///   transcript never lands in an unrelated window.
    @discardableResult
    public static func insert(_ text: String, targetPID: pid_t? = nil) async -> InsertOutcome {
        guard Permissions.accessibilityGranted(promptIfNeeded: true) else {
            copyToClipboard(text)
            Log.warn("Accessibility not granted; transcript left on clipboard")
            return .noAccessibility
        }

        // The stop hotkey is a ⌃⌥ chord; if the user still holds those keys
        // when ⌘V is posted, the target app receives ⌃⌥⌘V and nothing pastes.
        await waitForModifiersReleased()

        if let targetPID {
            let current = NSWorkspace.shared.frontmostApplication
            if let current, current.processIdentifier != targetPID {
                copyToClipboard(text)
                let name = current.localizedName ?? "another app"
                Log.warn("Frontmost app changed since recording; transcript left on clipboard")
                return .targetChanged(name)
            }
        }

        // 1. Preferred: write into the focused text element directly. Cannot be
        //    swallowed by apps that ignore synthetic events, and leaves the
        //    clipboard untouched.
        if insertViaAccessibility(text) {
            Log.info("Inserted via Accessibility API")
            return .insertedViaAccessibility
        }

        // 2. Fallback: clipboard + ⌘V (Electron, Chrome, terminals…).
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        let generation = pasteboard.clearContents()
        // Ask clipboard managers not to record the transcript.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setString(text, forType: .string)
        postCmdV()
        Log.info("Inserted via clipboard + ⌘V")

        // Restore the previous clipboard, but only if nothing else has written
        // to it since — otherwise we would clobber the user's newer copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pasteboard.changeCount == generation else { return }
            restore(saved, to: pasteboard)
        }
        return .pastedViaClipboard
    }

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Sets the focused element's selected text, which inserts at the caret
    /// (replacing any selection). Returns false when there is no focused text
    /// element or the app does not support the attribute.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedValue
        ) == .success, let focusedValue else { return false }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return false }
        let element = focusedValue as! AXUIElement

        // Only touch elements that actually hold editable text.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else { return false }

        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success
    }

    private static func waitForModifiersReleased(timeout: TimeInterval = 1.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        let watched: [CGKeyCode] = [
            CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl),
            CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption),
            CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift),
            CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand),
        ]
        while Date() < deadline {
            let anyDown = watched.contains { CGEventSource.keyState(.combinedSessionState, key: $0) }
            if !anyDown { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static func postCmdV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard preservation

    private struct SavedItem {
        var data: [NSPasteboard.PasteboardType: Data]
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [SavedItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let itemData = item.data(forType: type) {
                    data[type] = itemData
                }
            }
            return SavedItem(data: data)
        }
    }

    private static func restore(_ saved: [SavedItem], to pasteboard: NSPasteboard) {
        // Always drop the transcript first: an empty snapshot means "the
        // clipboard was empty", not "leave the transcript sitting there".
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { savedItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in savedItem.data {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
