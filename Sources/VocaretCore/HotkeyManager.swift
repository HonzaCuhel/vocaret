import AppKit
import Carbon.HIToolbox
import Foundation

public enum HotkeyError: Error, LocalizedError {
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            return "Hotkey registration failed (OSStatus \(status)) — is the combination taken by another app?"
        }
    }
}

public enum HotkeyID {
    public static let dictation: UInt32 = 1
    public static let meeting: UInt32 = 2
    public static let cancel: UInt32 = 3
}

/// Global hotkeys via Carbon — the one API that needs no Accessibility or
/// Input Monitoring permission, and swallows the keystroke system-wide.
public final class HotkeyManager {
    public static let shared = HotkeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: (() -> Void)?] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerInstalled = false

    private init() {}

    /// - Parameter onRelease: called when the chord is released. Supplying it
    ///   enables push-to-talk (hold to record, release to insert).
    public func register(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void,
        onRelease: (() -> Void)? = nil
    ) throws {
        installEventHandlerIfNeeded()
        unregister(id: id)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5643_5254), id: id) // 'VCRT'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            throw HotkeyError.registrationFailed(status)
        }
        refs[id] = ref
        handlers[id] = handler
        releaseHandlers[id] = onRelease
    }

    public func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
        releaseHandlers.removeValue(forKey: id)
    }

    fileprivate func fire(id: UInt32, released: Bool) {
        if released {
            releaseHandlers[id]??()
        } else {
            handlers[id]?()
        }
    }

    // MARK: - Release watching (push-to-talk)

    private var releaseMonitors: [Any] = []

    /// Carbon's `kEventHotKeyReleased` is not delivered reliably, so
    /// push-to-talk watches the real event stream instead: the chord counts as
    /// released as soon as the key comes up or the modifiers are let go.
    /// Requires Accessibility (already needed to insert text).
    public func beginReleaseWatch(keyCode: UInt32, modifiers: UInt32, onRelease: @escaping () -> Void) {
        endReleaseWatch()
        let required = Self.nsFlags(carbonModifiers: modifiers)
        var fired = false
        let handler: (NSEvent) -> Void = { event in
            guard !fired else { return }
            switch event.type {
            case .keyUp where UInt32(event.keyCode) == keyCode:
                fired = true
                onRelease()
            case .flagsChanged:
                let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !current.isSuperset(of: required) {
                    fired = true
                    onRelease()
                }
            default:
                break
            }
        }
        // Global monitor sees other apps' events; local sees our own.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp, .flagsChanged], handler: handler) {
            releaseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged], handler: { event in
            handler(event)
            return event
        }) {
            releaseMonitors.append(local)
        }
    }

    public func endReleaseWatch() {
        for monitor in releaseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        releaseMonitors.removeAll()
    }

    public static func nsFlags(carbonModifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    // MARK: - Helpers shared with UI / self-test

    /// Carbon modifier mask → CGEventFlags (for synthesizing the same chord).
    public static func cgFlags(carbonModifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        return flags
    }

    /// Human-readable chord like "⌃⌥D" for HUD/menu strings.
    public static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(keyCode)
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        let names: [UInt32: String] = [
            49: "Space", 53: "Esc", 36: "Return", 48: "Tab", 51: "Delete",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
            40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
            32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names[keyCode] ?? "key\(keyCode)"
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        // Both kinds: pressed drives toggle mode, released drives push-to-talk.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.fire(id: hotKeyID.id, released: released)
            }
            return noErr
        }
        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            2,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        eventHandlerInstalled = true
    }
}
