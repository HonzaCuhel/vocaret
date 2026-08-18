import Foundation

/// Every dictation is recorded here BEFORE insertion is attempted, so a
/// transcript can never be lost to a failed paste, a wrong target app, or a
/// permission that was revoked. Source of truth is `dictation-history.jsonl`
/// (one JSON record per line); a human-readable `dictation-history.md` is
/// kept alongside for people who just want to open a file.
public final class TranscriptHistory: @unchecked Sendable {
    public static let shared = TranscriptHistory(directory: SettingsStore.shared.appSupportDir)

    public struct Entry: Sendable {
        public let date: Date
        public let text: String
    }

    private let lock = NSLock()
    private let directory: URL?
    private var records: [DictationRecord] = []
    private var listeners: [UUID: @Sendable ([DictationRecord]) -> Void] = [:]

    public init(directory: URL?) {
        self.directory = directory
        load()
    }

    // MARK: - Reading

    public var last: Entry? {
        lock.lock(); defer { lock.unlock() }
        return records.last.map { Entry(date: $0.date, text: $0.text) }
    }

    public var recent: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return records.suffix(10).reversed().map { Entry(date: $0.date, text: $0.text) }
    }

    /// Newest first.
    public var all: [DictationRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.reversed()
    }

    public var fileURL: URL {
        (directory ?? FileManager.default.temporaryDirectory).appendingPathComponent("dictation-history.md")
    }

    private var jsonlURL: URL? { directory?.appendingPathComponent("dictation-history.jsonl") }

    // MARK: - Writing

    /// Legacy convenience — no timing information.
    public func record(_ text: String) {
        record(DictationRecord(date: Date(), text: text, recordingSeconds: 0, transcriptionSeconds: 0,
                               model: SettingsStore.shared.whisperModel))
    }

    public func record(_ record: DictationRecord) {
        let trimmed = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var stored = record
        stored.text = trimmed

        lock.lock()
        records.append(stored)
        let snapshot = records
        let callbacks = Array(listeners.values)
        lock.unlock()

        if SettingsStore.shared.keepDictationHistory {
            appendToDisk(stored)
        }
        for callback in callbacks { callback(snapshot) }
    }

    public func delete(id: UUID) {
        lock.lock()
        records.removeAll { $0.id == id }
        let snapshot = records
        let callbacks = Array(listeners.values)
        lock.unlock()
        rewriteDisk(snapshot)
        for callback in callbacks { callback(snapshot) }
    }

    public func clear() {
        lock.lock()
        records.removeAll()
        let callbacks = Array(listeners.values)
        lock.unlock()
        rewriteDisk([])
        for callback in callbacks { callback([]) }
    }

    /// UI observation. Returns a token; pass it to `removeListener`.
    @discardableResult
    public func addListener(_ callback: @escaping @Sendable ([DictationRecord]) -> Void) -> UUID {
        let token = UUID()
        lock.lock(); listeners[token] = callback; lock.unlock()
        return token
    }

    public func removeListener(_ token: UUID) {
        lock.lock(); listeners.removeValue(forKey: token); lock.unlock()
    }

    // MARK: - Persistence

    private func load() {
        guard let jsonlURL else { return }
        if let data = try? Data(contentsOf: jsonlURL), let text = String(data: data, encoding: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = text.split(separator: "\n").compactMap { line in
                try? decoder.decode(DictationRecord.self, from: Data(line.utf8))
            }
            return
        }
        // First run after the upgrade: import the old Markdown history so
        // nothing the user dictated before disappears from the dashboard.
        migrateMarkdown()
    }

    private func migrateMarkdown() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var imported: [DictationRecord] = []
        for line in text.components(separatedBy: "\n") where line.hasPrefix("- **") {
            // - **2026-08-17 18:44:12** text…
            guard let close = line.range(of: "** ") else { continue }
            let stamp = String(line[line.index(line.startIndex, offsetBy: 4)..<close.lowerBound])
            let body = String(line[close.upperBound...])
            guard let date = formatter.date(from: stamp) else { continue }
            imported.append(DictationRecord(date: date, text: body, recordingSeconds: 0, transcriptionSeconds: 0, model: "imported"))
        }
        guard !imported.isEmpty else { return }
        records = imported
        rewriteDisk(imported)
        Log.info("Imported \(imported.count) dictations from the old Markdown history")
    }

    private func appendToDisk(_ record: DictationRecord) {
        guard let jsonlURL, let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if var line = try? encoder.encode(record) {
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: jsonlURL) {
                handle.seekToEndOfFile(); handle.write(line); try? handle.close()
            } else {
                try? line.write(to: jsonlURL)
            }
        }
        let stamp = Self.formatter.string(from: record.date)
        let mdLine = "- **\(stamp)** \(record.text)\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile(); handle.write(Data(mdLine.utf8)); try? handle.close()
        } else {
            try? ("# Vocaret dictation history\n\n" + mdLine).write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func rewriteDisk(_ records: [DictationRecord]) {
        guard let jsonlURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = records.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: jsonlURL, atomically: true, encoding: .utf8)
        let md = "# Vocaret dictation history\n\n" + records.map { "- **\(Self.formatter.string(from: $0.date))** \($0.text)" }.joined(separator: "\n") + "\n"
        try? md.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
