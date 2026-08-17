import AppKit
import Carbon.HIToolbox

/// Inserts text at the current keyboard caret of whatever app is focused,
/// Wispr-Flow style: put the transcript on the clipboard, synthesize ⌘V,
/// then restore the previous clipboard contents.
@MainActor
public enum TextInserter {

    /// Returns true if the text was pasted; false if it was only left on the
    /// clipboard (Accessibility not granted yet).
    @discardableResult
    public static func insert(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard Permissions.accessibilityGranted(promptIfNeeded: true) else {
            Log.warn("Accessibility not granted; transcript left on clipboard")
            return false
        }

        // The stop hotkey is a ⌃⌥ chord; if the user still holds those keys
        // when ⌘V is posted, the target app receives ⌃⌥⌘V and nothing pastes.
        await waitForModifiersReleased()
        postCmdV()

        // Give the target app a moment to consume the paste before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            restore(saved, to: pasteboard)
        }
        return true
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
        guard !saved.isEmpty else { return }
        pasteboard.clearContents()
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
