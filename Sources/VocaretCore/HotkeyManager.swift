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

/// One logical press per physical hold, shared by Carbon and release watchers.
/// Hardware polling is armed only after the chord was observed down; otherwise
/// unavailable hardware state or synthesized shortcuts would look like key-up.
struct HotkeyPressState {
    private(set) var isPressed = false
    private var observedHardwareDown = false
    private var consecutiveUpSamples = 0

    mutating func press(chordIsDown: Bool) -> Bool {
        guard !isPressed else { return false }
        isPressed = true
        observedHardwareDown = chordIsDown
        consecutiveUpSamples = 0
        return true
    }

    mutating func release(chordIsDown: Bool) -> Bool {
        guard isPressed else { return false }
        if chordIsDown {
            observedHardwareDown = true
            consecutiveUpSamples = 0
            return false
        }
        isPressed = false
        observedHardwareDown = false
        consecutiveUpSamples = 0
        return true
    }

    mutating func poll(chordIsDown: Bool) -> Bool {
        guard isPressed else { return false }
        if chordIsDown {
            observedHardwareDown = true
            consecutiveUpSamples = 0
            return false
        }
        guard observedHardwareDown else { return false }
        consecutiveUpSamples += 1
        // Require two samples so a transient hardware-state read cannot stop
        // recording. Actual release events still take effect immediately.
        guard consecutiveUpSamples >= 2 else { return false }
        return release(chordIsDown: false)
    }
}

/// Global hotkeys via Carbon — the one API that needs no Accessibility or
/// Input Monitoring permission, and swallows the keystroke system-wide.
public final class HotkeyManager {
    public static let shared = HotkeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: (() -> Void)?] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var chords: [UInt32: (keyCode: UInt32, modifiers: UInt32)] = [:]
    private var pressStates: [UInt32: HotkeyPressState] = [:]
    private var physicalReleaseTimer: DispatchSourceTimer?
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
        chords[id] = (keyCode, modifiers)
        pressStates[id] = HotkeyPressState()
    }

    public func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
        releaseHandlers.removeValue(forKey: id)
        chords.removeValue(forKey: id)
        pressStates.removeValue(forKey: id)
        stopPhysicalReleaseTimerIfIdle()
    }

    fileprivate func fire(id: UInt32, released: Bool) {
        guard let chord = chords[id] else { return }
        let chordIsDown = Self.isChordPhysicallyDown(keyCode: chord.keyCode, modifiers: chord.modifiers)
        if released {
            guard pressStates[id]?.release(chordIsDown: chordIsDown) == true else { return }
            stopPhysicalReleaseTimerIfIdle()
            releaseHandlers[id]??()
        } else {
            guard pressStates[id]?.press(chordIsDown: chordIsDown) == true else { return }
            startPhysicalReleaseTimerIfNeeded()
            handlers[id]?()
        }
    }

    private static func isChordPhysicallyDown(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard let key = CGKeyCode(exactly: keyCode),
              CGEventSource.keyState(.hidSystemState, key: key) else { return false }
        return CGEventSource.flagsState(.hidSystemState).isSuperset(of: cgFlags(carbonModifiers: modifiers))
    }

    private func startPhysicalReleaseTimerIfNeeded() {
        guard physicalReleaseTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for id in Array(self.pressStates.keys) {
                guard let chord = self.chords[id] else { continue }
                let down = Self.isChordPhysicallyDown(keyCode: chord.keyCode, modifiers: chord.modifiers)
                if self.pressStates[id]?.poll(chordIsDown: down) == true {
                    self.releaseHandlers[id]??()
                }
            }
            self.stopPhysicalReleaseTimerIfIdle()
        }
        physicalReleaseTimer = timer
        timer.resume()
    }

    private func stopPhysicalReleaseTimerIfIdle() {
        guard !pressStates.values.contains(where: \.isPressed) else { return }
        physicalReleaseTimer?.cancel()
        physicalReleaseTimer = nil
    }

    private func acceptWatchedRelease(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard !Self.isChordPhysicallyDown(keyCode: keyCode, modifiers: modifiers) else { return false }
        let matchingIDs = chords.compactMap { id, chord in
            chord.keyCode == keyCode && chord.modifiers == modifiers ? id : nil
        }
        var accepted = matchingIDs.isEmpty
        for id in matchingIDs {
            if pressStates[id]?.release(chordIsDown: false) == true { accepted = true }
        }
        stopPhysicalReleaseTimerIfIdle()
        return accepted
    }

    // MARK: - Release watching (push-to-talk)

    private var releaseMonitors: [Any] = []

    /// Carbon's `kEventHotKeyReleased` is not delivered reliably, so
    /// push-to-talk also watches the event stream: the chord counts as
    /// released as soon as the key comes up or the modifiers are let go.
    /// Requires Accessibility (already needed to insert text).
    public func beginReleaseWatch(keyCode: UInt32, modifiers: UInt32, onRelease: @escaping () -> Void) {
        endReleaseWatch()
        let required = Self.nsFlags(carbonModifiers: modifiers)
        var fired = false
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self, !fired else { return }
            let released: Bool
            switch event.type {
            case .keyUp where UInt32(event.keyCode) == keyCode:
                released = true
            case .flagsChanged:
                let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                released = !current.isSuperset(of: required)
            default:
                released = false
            }
            guard released, self.acceptWatchedRelease(keyCode: keyCode, modifiers: modifiers) else { return }
            fired = true
            onRelease()
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
