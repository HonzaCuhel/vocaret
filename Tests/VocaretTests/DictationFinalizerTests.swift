import XCTest
@testable import VocaretCore

@MainActor
final class DictationFinalizerTests: XCTestCase {
    func testOnlyFinalFormattedTextReachesHistoryHUDCompanionAndClipboardFallback() async throws {
        let raw = "rozpočet je 20 000 Kč teda 30 000 Kč a projekt vocaret začíná v pondělí"
        let formatted = "Rozpočet je 30 000 Kč a projekt vocaret začíná v pondělí."
        let final = "Rozpočet je 30 000 Kč a projekt Vocaret začíná v pondělí."
        let history = TranscriptHistory(directory: nil)
        var learned: [(String, String)] = []
        let finalized = try await DictationFinalizer.finalize(
            rawText: raw, recordingSeconds: 90, transcriptionStarted: Date(), model: "test",
            cleanup: { input in
                XCTAssertEqual(input, raw)
                XCTAssertNil(history.last, "Unfinished raw ASR must not replace Copy Last")
                XCTAssertTrue(CleanupGuard.isSafe(original: input, cleaned: formatted))
                return DictationCleanupResult(text: formatted, failure: nil)
            },
            learnCorrections: { learned.append(($0, $1)) },
            correct: { $0.replacingOccurrences(of: "vocaret", with: "Vocaret") }
        )
        var hudText = raw
        var companionText = ""
        var fallbackClipboard = ""
        let outcome = try await DictationFinalizer.deliver(
            finalized, history: history,
            present: { hudText = $0; companionText = $0 },
            insert: { text in
                XCTAssertEqual(history.last?.text, final, "History must be ready before insertion can fail")
                fallbackClipboard = text
                return .noAccessibility
            }
        )
        var menuClipboard = ""
        XCTAssertTrue(DictationFinalizer.copyLast(from: history) { menuClipboard = $0 })

        XCTAssertEqual(outcome, .noAccessibility)
        XCTAssertEqual(hudText, final)
        XCTAssertEqual(companionText, final)
        XCTAssertEqual(fallbackClipboard, final)
        XCTAssertEqual(menuClipboard, final)
        XCTAssertEqual(history.last?.text, final)
        XCTAssertEqual(history.recent.map(\.text), [final])
        XCTAssertEqual(history.all.first?.cleaned, true)
        XCTAssertEqual(learned.first?.0, raw)
        XCTAssertEqual(learned.first?.1, formatted)
        XCTAssertNil(finalized.cleanupFailure)
    }

    func testCleanupFailureKeepsFallbackAvailableWithoutClaimingItWasFormatted() async throws {
        for failure in [DictationCleanupFailure.unavailable, .incomplete, .rejected] {
            let raw = "Neztratit žádná původní slova při chybě formátování"
            let history = TranscriptHistory(directory: nil)
            var learned = false
            let finalized = try await DictationFinalizer.finalize(
                rawText: raw, recordingSeconds: 90, transcriptionStarted: Date(), model: "test",
                cleanup: { DictationCleanupResult(text: $0, failure: failure) },
                learnCorrections: { _, _ in learned = true },
                correct: { $0 }
            )
            let outcome = try await DictationFinalizer.deliver(finalized, history: history, present: { _ in }) { _ in
                .targetChanged("Test editor")
            }
            var copied = ""
            XCTAssertTrue(DictationFinalizer.copyLast(from: history) { copied = $0 })

            XCTAssertEqual(copied, raw)
            XCTAssertEqual(history.all.first?.cleaned, false)
            XCTAssertEqual(finalized.cleanupFailure, failure)
            XCTAssertEqual(outcome, .targetChanged("Test editor"))
            XCTAssertFalse(learned)
        }
    }

    func testDisabledCleanupStillAppliesUserSpellingWithoutClaimingFormatting() async throws {
        let finalized = try await DictationFinalizer.finalize(
            rawText: "vocaret", recordingSeconds: 2, transcriptionStarted: Date(), model: "test",
            cleanup: nil, learnCorrections: { _, _ in XCTFail("Cleanup is disabled") },
            correct: { _ in "Vocaret" }
        )

        XCTAssertEqual(finalized.record.text, "Vocaret")
        XCTAssertFalse(finalized.record.cleaned)
        XCTAssertNil(finalized.cleanupFailure)
    }

    func testFinalWhitespaceIsIdenticalInHistoryAndInsertion() async throws {
        let history = TranscriptHistory(directory: nil)
        let finalized = try await DictationFinalizer.finalize(
            rawText: " \nHotový text.  ", recordingSeconds: 2, transcriptionStarted: Date(), model: "test",
            cleanup: nil, learnCorrections: { _, _ in }, correct: { $0 }
        )
        var inserted = ""
        try await DictationFinalizer.deliver(finalized, history: history, present: { _ in }) {
            inserted = $0
            return .noAccessibility
        }

        XCTAssertEqual(inserted, "Hotový text.")
        XCTAssertEqual(history.last?.text, inserted)
    }

    func testSuccessfulUnchangedCleanupIsStillMarkedFormatted() async throws {
        let finalized = try await DictationFinalizer.finalize(
            rawText: "Already formatted.", recordingSeconds: 2, transcriptionStarted: Date(), model: "test",
            cleanup: { DictationCleanupResult(text: $0, failure: nil) },
            learnCorrections: { _, _ in }, correct: { $0 }
        )

        XCTAssertTrue(finalized.record.cleaned)
        XCTAssertNil(finalized.cleanupFailure)
    }

    func testCancellationDuringCleanupCannotProduceARecordForDelivery() async {
        let task = Task { @MainActor in
            try await DictationFinalizer.finalize(
                rawText: "Cancelled text", recordingSeconds: 2, transcriptionStarted: Date(), model: "test",
                cleanup: { text in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return DictationCleanupResult(text: text, failure: nil)
                },
                learnCorrections: { _, _ in XCTFail("Cancelled cleanup must not teach corrections") },
                correct: { _ in XCTFail("Cancelled cleanup must not be delivered"); return "" }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCopyLastWithoutHistoryDoesNotOverwriteClipboard() {
        let history = TranscriptHistory(directory: nil)
        var copied = "existing clipboard"
        XCTAssertFalse(DictationFinalizer.copyLast(from: history) { copied = $0 })
        XCTAssertEqual(copied, "existing clipboard")
    }
}
