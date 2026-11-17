import XCTest
@testable import VocaretCore

@MainActor
final class DictationStartupTests: XCTestCase {
    func testLateCancelledPermissionResultCannotClearANewerStartup() async {
        let firstGate = StartupTestGate()
        let secondGate = StartupTestGate()
        let firstStarted = expectation(description: "first permission request")
        let secondStarted = expectation(description: "second permission request")
        var calls = 0
        let previous = SettingsStore.shared.showHUD
        SettingsStore.shared.showHUD = true
        CompanionModel.shared.capturing = false
        let controller = DictationController(requestMicrophone: {
            calls += 1
            if calls == 1 {
                firstStarted.fulfill()
                await firstGate.wait()
            } else {
                secondStarted.fulfill()
                await secondGate.wait()
            }
            return false
        })
        defer {
            controller.cancel()
            HUD.shared.hide(immediately: true)
            SettingsStore.shared.showHUD = previous
        }
        controller.toggle()
        await fulfillment(of: [firstStarted], timeout: 2)
        controller.cancel()
        controller.toggle()
        await fulfillment(of: [secondStarted], timeout: 2)
        await firstGate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(CompanionModel.shared.capturing)
        XCTAssertEqual(HUD.shared.model.phase, .transcribing)
        controller.cancel()
        await secondGate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(CompanionModel.shared.capturing)
        XCTAssertEqual(HUD.shared.model.phase, .hidden)
    }

    func testStartingIsVisibleAndCancellationCannotBeUndoneByLatePermissionResult() async {
        let gate = StartupTestGate()
        let started = expectation(description: "request entered")
        let previous = SettingsStore.shared.showHUD
        SettingsStore.shared.showHUD = true
        CompanionModel.shared.capturing = false
        let controller = DictationController(requestMicrophone: {
            started.fulfill()
            await gate.wait()
            return false
        })
        defer {
            controller.cancel()
            HUD.shared.hide(immediately: true)
            SettingsStore.shared.showHUD = previous
        }
        controller.toggle()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(HUD.shared.isPanelVisible)
        XCTAssertEqual(HUD.shared.model.phase, .transcribing)
        XCTAssertTrue(CompanionModel.shared.capturing)
        controller.cancel()
        XCTAssertFalse(HUD.shared.isPanelVisible)
        XCTAssertFalse(CompanionModel.shared.capturing)
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(HUD.shared.model.phase, .hidden)
        XCTAssertFalse(HUD.shared.isPanelVisible)
    }
}

private actor StartupTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
