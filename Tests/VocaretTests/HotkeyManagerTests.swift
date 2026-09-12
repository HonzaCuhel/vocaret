import Carbon.HIToolbox
import XCTest
@testable import VocaretCore

final class HotkeyManagerTests: XCTestCase {
    @MainActor
    func testRepeatedCarbonPressesDoNotToggleARecordingOff() async throws {
        let id: UInt32 = 10_001
        var presses = 0
        try HotkeyManager.shared.register(
            id: id,
            keyCode: UInt32(kVK_F20),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            handler: { presses += 1 }
        )
        defer { HotkeyManager.shared.unregister(id: id) }
        try sendHotkeyEvent(id: id, released: false)
        try sendHotkeyEvent(id: id, released: false)
        try sendHotkeyEvent(id: id, released: false)
        // Carbon dispatches the application handler onto the main queue.
        await drainMainQueue()
        XCTAssertEqual(presses, 1, "A held shortcut must cause one toggle, regardless of repeated press events")
    }

    @MainActor
    func testQuickTapThenSecondPressStillToggles() async throws {
        let id: UInt32 = 10_002
        var presses = 0
        var releases = 0
        try HotkeyManager.shared.register(
            id: id,
            keyCode: UInt32(kVK_F20),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey),
            handler: { presses += 1 },
            onRelease: { releases += 1 }
        )
        defer { HotkeyManager.shared.unregister(id: id) }
        try sendHotkeyEvent(id: id, released: false)
        try sendHotkeyEvent(id: id, released: true)
        try sendHotkeyEvent(id: id, released: true)
        try sendHotkeyEvent(id: id, released: false)
        await drainMainQueue()
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(releases, 1, "Duplicate release delivery must not turn a short tap into a later hold release")
    }

    func testLongHoldIgnoresRepeatedPressesAndFalseReleases() {
        var state = HotkeyPressState()
        XCTAssertTrue(state.press(chordIsDown: true))
        // Ninety seconds at the hardware watcher's 50 ms interval.
        for _ in 0..<1_800 {
            XCTAssertFalse(state.press(chordIsDown: true))
            XCTAssertFalse(state.release(chordIsDown: true))
            XCTAssertFalse(state.poll(chordIsDown: true))
        }
        XCTAssertTrue(state.release(chordIsDown: false))
        XCTAssertFalse(state.release(chordIsDown: false))
        XCTAssertTrue(state.press(chordIsDown: true))
    }

    func testPhysicalReleaseRecoversWhenCarbonAndEventMonitorsMissIt() {
        var state = HotkeyPressState()
        XCTAssertTrue(state.press(chordIsDown: true))
        XCTAssertFalse(state.poll(chordIsDown: false))
        XCTAssertTrue(state.poll(chordIsDown: false))
        XCTAssertFalse(state.poll(chordIsDown: false))
        XCTAssertTrue(state.press(chordIsDown: true), "A missed release must not make the next tap unresponsive")
    }

    func testOneTransientHardwareSampleDoesNotEndTheHold() {
        var state = HotkeyPressState()
        XCTAssertTrue(state.press(chordIsDown: true))
        XCTAssertFalse(state.poll(chordIsDown: false))
        XCTAssertFalse(state.poll(chordIsDown: true))
        XCTAssertFalse(state.poll(chordIsDown: false))
        XCTAssertFalse(state.release(chordIsDown: true))
        XCTAssertFalse(state.poll(chordIsDown: false))
        XCTAssertTrue(state.poll(chordIsDown: false))
    }

    func testUnobservedHardwareDoesNotManufactureARelease() {
        var state = HotkeyPressState()
        // Synthesized shortcuts, or an unavailable hardware state, can still
        // deliver valid Carbon events without ever appearing as physically down.
        XCTAssertTrue(state.press(chordIsDown: false))
        for _ in 0..<20 {
            XCTAssertFalse(state.poll(chordIsDown: false))
        }
        XCTAssertTrue(state.release(chordIsDown: false))
    }

    func testHardwareWatchArmsWhenTheChordBecomesObservable() {
        var state = HotkeyPressState()
        XCTAssertTrue(state.press(chordIsDown: false))
        XCTAssertFalse(state.poll(chordIsDown: true))
        XCTAssertFalse(state.poll(chordIsDown: false))
        XCTAssertTrue(state.poll(chordIsDown: false))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func sendHotkeyEvent(id: UInt32, released: Bool) throws {
        var event: EventRef?
        let kind = released ? kEventHotKeyReleased : kEventHotKeyPressed
        let createStatus = CreateEvent(
            nil, OSType(kEventClassKeyboard), UInt32(kind), 0,
            EventAttributes(kEventAttributeUserEvent), &event
        )
        guard createStatus == noErr, let event else {
            throw HotkeyError.registrationFailed(createStatus)
        }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: OSType(0x5643_5254), id: id)
        let parameterStatus = SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &hotKeyID
        )
        guard parameterStatus == noErr else { throw HotkeyError.registrationFailed(parameterStatus) }
        let status = SendEventToEventTarget(event, GetEventDispatcherTarget())
        guard status == noErr else { throw HotkeyError.registrationFailed(status) }
    }
}
