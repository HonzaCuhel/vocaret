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
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerInstalled = false

    private init() {}

    public func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        installEventHandlerIfNeeded()
        unregister(id: id)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4A53_4954), id: id) // 'JSIT'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            throw HotkeyError.registrationFailed(status)
        }
        refs[id] = ref
        handlers[id] = handler
    }

    public func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
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
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.fire(id: hotKeyID.id)
            }
            return noErr
        }
        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        eventHandlerInstalled = true
    }
}
