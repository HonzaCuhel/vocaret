import XCTest
@testable import VocaretCore

final class DictationGestureStateTests: XCTestCase {
    func testQuickTapRemainsATapAfterSlowRecordingStartup() {
        var gesture = DictationGestureState()
        gesture.begin(at: Date(timeIntervalSinceReferenceDate: 100))
        gesture.release(at: Date(timeIntervalSinceReferenceDate: 100.1))

        let startupCompleted = Date(timeIntervalSinceReferenceDate: 101.5)
        XCTAssertTrue(gesture.wasReleased)
        XCTAssertFalse(gesture.isHeld)
        XCTAssertEqual(gesture.heldDuration(at: startupCompleted), 0.1, accuracy: 0.001)
        XCTAssertLessThan(gesture.heldDuration(at: startupCompleted), 0.35)
    }

    func testRealHoldBeforeStartupStillFinishesOnStartup() {
        var gesture = DictationGestureState()
        gesture.begin(at: Date(timeIntervalSinceReferenceDate: 100))
        gesture.release(at: Date(timeIntervalSinceReferenceDate: 100.6))

        XCTAssertTrue(gesture.wasReleased)
        XCTAssertGreaterThanOrEqual(gesture.heldDuration(at: Date(timeIntervalSinceReferenceDate: 102)), 0.35)
    }

    func testDuplicateReleaseCannotTurnATapIntoAHold() {
        var gesture = DictationGestureState()
        gesture.begin(at: Date(timeIntervalSinceReferenceDate: 100))
        gesture.release(at: Date(timeIntervalSinceReferenceDate: 100.1))
        gesture.release(at: Date(timeIntervalSinceReferenceDate: 101))

        XCTAssertEqual(gesture.heldDuration(at: Date(timeIntervalSinceReferenceDate: 102)), 0.1, accuracy: 0.001)
    }

    func testNewPressClearsThePreviousRelease() {
        var gesture = DictationGestureState()
        gesture.begin(at: Date(timeIntervalSinceReferenceDate: 100))
        gesture.release(at: Date(timeIntervalSinceReferenceDate: 101))
        gesture.begin(at: Date(timeIntervalSinceReferenceDate: 200))

        XCTAssertTrue(gesture.isHeld)
        XCTAssertFalse(gesture.wasReleased)
        XCTAssertEqual(gesture.heldDuration(at: Date(timeIntervalSinceReferenceDate: 200.2)), 0.2, accuracy: 0.001)
    }
}
