import Foundation

/// A small, bounded bridge from the real-time audio callback to async network
/// I/O. Dropping live audio makes the cloud transcript incomplete, so overflow
/// closes the stream and lets the controller fall back to its retained local
/// recording instead of silently returning partial text.
final class LiveAudioChunkBuffer: @unchecked Sendable {
    let stream: AsyncStream<[Float]>

    private let continuation: AsyncStream<[Float]>.Continuation
    private let lock = NSLock()
    private var overflowed = false

    init(capacity: Int) {
        precondition(capacity > 0)
        let pair = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    /// Returns false when the stream is closed or this chunk overflowed it.
    @discardableResult
    func yield(_ samples: [Float]) -> Bool {
        switch continuation.yield(samples) {
        case .enqueued:
            return true
        case .dropped:
            lock.lock()
            overflowed = true
            lock.unlock()
            continuation.finish()
            return false
        case .terminated:
            return false
        @unknown default:
            continuation.finish()
            return false
        }
    }

    var hasOverflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
    }

    func finish() {
        continuation.finish()
    }
}
