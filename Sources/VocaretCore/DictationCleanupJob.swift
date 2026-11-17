import Foundation

/// One interaction owns one completion. Skip, cancellation and the deadline
/// return immediately even if a model is inside cancellation-insensitive work.
@MainActor
final class DictationCleanupJob {
    private var continuation: CheckedContinuation<DictationCleanupResult, Never>?
    private var worker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var original = ""

    func run(
        text: String, timeout: TimeInterval,
        operation: @escaping @MainActor () async -> DictationCleanupResult
    ) async -> DictationCleanupResult {
        original = text
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    resolve(DictationCleanupResult(text: text, failure: .unavailable))
                    return
                }
                worker = Task {
                    let result = await operation()
                    resolve(result)
                }
                deadline = Task {
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    resolve(DictationCleanupResult(text: text, failure: .unavailable))
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.resolve(DictationCleanupResult(text: text, failure: .unavailable))
            }
        }
    }

    func skip() {
        resolve(DictationCleanupResult(text: original, failure: .skipped))
    }

    private func resolve(_ result: DictationCleanupResult) {
        guard let continuation else { return }
        self.continuation = nil
        worker?.cancel()
        worker = nil
        deadline?.cancel()
        deadline = nil
        continuation.resume(returning: result)
    }
}
