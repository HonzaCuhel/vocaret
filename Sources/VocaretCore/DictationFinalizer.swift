import Foundation

struct FinalizedDictation {
    let record: DictationRecord
    let cleanupFailure: DictationCleanupFailure?
}

/// All delivery paths consume one final record, after formatting and personal
/// spellings. Dependencies are explicit so failures can be tested without the
/// user's microphone, history files, clipboard, or model account.
@MainActor
enum DictationFinalizer {
    static func finalize(
        rawText: String,
        recordingSeconds: Double,
        transcriptionStarted: Date,
        model: String,
        cleanup: ((String) async -> DictationCleanupResult)?,
        learnCorrections: (String, String) -> Void,
        correct: (String) -> String
    ) async throws -> FinalizedDictation {
        try Task.checkCancellation()
        var result = await cleanup?(rawText)
        try Task.checkCancellation()
        // Check against the ASR source too: a formatter may have applied
        // personal aliases before its own validation.
        if let output = result, output.isFormatted,
           CleanupGuard.changesConfidentLanguage(original: rawText, cleaned: output.text) {
            result = DictationCleanupResult(text: rawText, failure: .rejected)
        }
        if let result, result.isFormatted {
            learnCorrections(rawText, result.text)
        }
        let corrected = correct(result?.text ?? rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        let languageChanged = CleanupGuard.changesConfidentLanguage(original: rawText, cleaned: corrected)
        let text = languageChanged ? rawText.trimmingCharacters(in: .whitespacesAndNewlines) : corrected
        return FinalizedDictation(
            record: DictationRecord(
                date: Date(), text: text,
                recordingSeconds: recordingSeconds,
                transcriptionSeconds: Date().timeIntervalSince(transcriptionStarted),
                model: model, cleaned: !languageChanged && result?.isFormatted == true
            ),
            cleanupFailure: languageChanged ? .rejected : result?.failure
        )
    }

    @discardableResult
    static func deliver(
        _ finalized: FinalizedDictation,
        history: TranscriptHistory,
        present: (String) -> Void,
        insert: (String) async -> InsertOutcome?
    ) async throws -> InsertOutcome? {
        try Task.checkCancellation()
        // Copy Last is already ready if insertion is refused or never arrives.
        history.record(finalized.record)
        present(finalized.record.text)
        return await insert(finalized.record.text)
    }

    @discardableResult
    static func copyLast(from history: TranscriptHistory, write: (String) -> Void) -> Bool {
        guard let entry = history.last else { return false }
        write(entry.text)
        return true
    }
}
