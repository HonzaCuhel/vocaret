import XCTest
@testable import VocaretCore

@MainActor
final class DictationCleanupJobTests: XCTestCase {
    func testSkipReturnsRawTextWithoutWaitingForUncooperativeFormatter() async {
        let job = DictationCleanupJob()
        let started = expectation(description: "formatter started")
        let release = CleanupTestGate()
        let task = Task {
            await job.run(text: "Ahoj. Hello.", timeout: 30) {
                started.fulfill()
                await release.wait()
                return DictationCleanupResult(text: "Late formatted text", failure: nil)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let start = ContinuousClock.now
        job.skip()
        let result = await task.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(result.text, "Ahoj. Hello.")
        XCTAssertEqual(result.failure, .skipped)
        await release.open()
    }

    func testDeadlineIncludesFormatterStartupAndReturnsRawText() async {
        let job = DictationCleanupJob()
        let release = CleanupTestGate()
        let start = ContinuousClock.now
        let result = await job.run(text: "Raw text", timeout: 0.02) {
            await release.wait()
            return DictationCleanupResult(text: "Late text", failure: nil)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(result.text, "Raw text")
        XCTAssertEqual(result.failure, .unavailable)
        await release.open()
    }

    func testCompletedFormattingWinsAndLaterSkipHasNoEffect() async {
        let job = DictationCleanupJob()
        let result = await job.run(text: "ahoj", timeout: 1) {
            DictationCleanupResult(text: "Ahoj.", failure: nil)
        }
        job.skip()
        XCTAssertEqual(result.text, "Ahoj.")
        XCTAssertTrue(result.isFormatted)
    }

    func testCancellationReturnsPromptlyEvenWhenFormatterIgnoresCancellation() async {
        let job = DictationCleanupJob()
        let started = expectation(description: "formatter started")
        let release = CleanupTestGate()
        let task = Task {
            await job.run(text: "Original", timeout: 30) {
                started.fulfill()
                await release.wait()
                return DictationCleanupResult(text: "Late", failure: nil)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.text, "Original")
        XCTAssertFalse(result.isFormatted)
        await release.open()
    }
}

private actor CleanupTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
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
