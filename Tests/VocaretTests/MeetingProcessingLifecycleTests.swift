import XCTest
@testable import VocaretCore

@MainActor
final class MeetingProcessingLifecycleTests: XCTestCase {
    func testMeetingPreparationIsVisibleAndLatePermissionCannotUndoCancellation() async {
        let gate = MeetingFinishGate()
        let entered = expectation(description: "permission requested")
        let savedHUD = SettingsStore.shared.showHUD
        SettingsStore.shared.showHUD = true
        CompanionModel.shared.capturing = false
        let controller = MeetingController(requestMicrophone: {
            entered.fulfill()
            await gate.wait()
            return false
        }, acknowledgeConsent: { true })
        defer { controller.cancel(); HUD.shared.hide(immediately: true); SettingsStore.shared.showHUD = savedHUD }
        controller.toggle()
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(HUD.shared.isPanelVisible)
        XCTAssertEqual(HUD.shared.model.phase, .transcribing)
        controller.cancel()
        XCTAssertFalse(HUD.shared.isPanelVisible)
        XCTAssertFalse(CompanionModel.shared.capturing)
        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(HUD.shared.model.phase, .hidden)
    }

    func testCancellationStopsFinishingSessionAndReleasesThePanel() async {
        let settings = SettingsStore.shared
        let previousHUD = settings.showHUD
        settings.showHUD = true
        let controller = MeetingController()
        let session = BlockingMeetingFinish()
        let entered = expectation(description: "finishing started")
        defer { controller.cancel(); HUD.shared.hide(immediately: true); settings.showHUD = previousHUD }
        controller.startProcessing(session: session) {
            entered.fulfill()
            _ = await session.finish()
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(controller.state, .processing)
        controller.cancel()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(session.wasCancelled)
        XCTAssertFalse(CompanionModel.shared.capturing)
    }

    func testLateCancelledProcessingCannotFinishANewerMeetingJob() async {
        let previousHUD = SettingsStore.shared.showHUD
        SettingsStore.shared.showHUD = true
        let controller = MeetingController()
        let first = BlockingMeetingFinish(releaseOnCancel: false)
        let second = BlockingMeetingFinish()
        let entered = expectation(description: "first job entered")
        let returned = expectation(description: "old job returned")
        defer { controller.cancel(); HUD.shared.hide(immediately: true); SettingsStore.shared.showHUD = previousHUD }
        controller.startProcessing(session: first) {
            entered.fulfill()
            _ = await first.finish()
            returned.fulfill()
        }
        await fulfillment(of: [entered], timeout: 2)
        controller.cancel()
        controller.startProcessing(session: second) { _ = await second.finish() }
        await first.release()
        await fulfillment(of: [returned], timeout: 2)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.state, .processing)
        XCTAssertTrue(CompanionModel.shared.capturing)
        XCTAssertFalse(second.wasCancelled)
    }
}

private final class BlockingMeetingFinish: MeetingSession, @unchecked Sendable {
    private let gate = MeetingFinishGate()
    private let lock = NSLock()
    private var cancelled = false
    private let releaseOnCancel: Bool
    init(releaseOnCancel: Bool = true) { self.releaseOnCancel = releaseOnCancel }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func append(_ samples: [Float], speaker: Speaker) {}
    func finish() async -> MeetingTranscriptionResult { await gate.wait(); return .init() }
    func release() async { await gate.release() }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if releaseOnCancel { Task { await gate.release() } }
    }
}

private actor MeetingFinishGate {
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !open { await withCheckedContinuation { continuation = $0 } } }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
