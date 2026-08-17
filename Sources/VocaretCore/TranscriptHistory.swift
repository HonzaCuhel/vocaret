import Foundation

/// Every dictation is recorded here BEFORE insertion is attempted, so a
/// transcript can never be lost to a failed paste, a wrong target app, or a
/// permission that was revoked. Retrievable from the menu bar.
public final class TranscriptHistory: @unchecked Sendable {
    public static let shared = TranscriptHistory()

    public struct Entry: Sendable {
        public let date: Date
        public let text: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let limit = 50

    public init() {}

    public var last: Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last
    }

    public var recent: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.suffix(10).reversed()
    }

    public var fileURL: URL {
        SettingsStore.shared.appSupportDir.appendingPathComponent("dictation-history.md")
    }

    public func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        entries.append(Entry(date: Date(), text: trimmed))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()

        guard SettingsStore.shared.keepDictationHistory else { return }
        let stamp = Self.formatter.string(from: Date())
        let line = "- **\(stamp)** \(trimmed)\n"
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? ("# Vocaret dictation history\n\n" + line).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
