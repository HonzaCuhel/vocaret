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
    /// All file writes go through here so an append from a finishing
    /// dictation cannot interleave with a rewrite from a delete.
    private let diskQueue = DispatchQueue(label: "vocaret.history.disk")
    private let directory: URL?
    private var records: [DictationRecord] = []
    /// Records that are actually in the JSONL file. With "keep dictation
    /// history" off, records live in memory only and must never be promoted
    /// to disk by a later delete/rewrite.
    private var persistedIDs = Set<UUID>()
    /// Lines of the JSONL we could not decode (hand edits, a future format).
    /// Carried through rewrites verbatim instead of being silently dropped.
    private var unreadableLines: [String] = []
    /// The file exists but could not be read at all — never rewrite it.
    private var diskIsUntrusted = false
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

        let keep = SettingsStore.shared.keepDictationHistory
        lock.lock()
        records.append(stored)
        if keep { persistedIDs.insert(stored.id) }
        let snapshot = records
        let callbacks = Array(listeners.values)
        lock.unlock()

        if keep {
            appendToDisk(stored)
        }
        for callback in callbacks { callback(snapshot) }
    }

    public func delete(id: UUID) {
        lock.lock()
        records.removeAll { $0.id == id }
        persistedIDs.remove(id)
        let snapshot = records
        let onDisk = records.filter { persistedIDs.contains($0.id) }
        let callbacks = Array(listeners.values)
        lock.unlock()
        rewriteDisk(onDisk)
        for callback in callbacks { callback(snapshot) }
    }

    public func clear() {
        lock.lock()
        records.removeAll()
        persistedIDs.removeAll()
        unreadableLines.removeAll()
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
        guard FileManager.default.fileExists(atPath: jsonlURL.path) else {
            // First run after the upgrade: import the old Markdown history so
            // nothing the user dictated before disappears from the dashboard.
            migrateMarkdown()
            return
        }
        guard let data = try? Data(contentsOf: jsonlURL) else {
            Log.error("Could not read \(jsonlURL.lastPathComponent) — starting with an empty history; the file is left untouched")
            diskIsUntrusted = true
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Lossy decoding: a truncated multi-byte character at the end of the
        // file must not make the whole history "unreadable".
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        var loaded: [DictationRecord] = []
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let record = try? decoder.decode(DictationRecord.self, from: Data(line.utf8)) {
                loaded.append(record)
            } else {
                unreadableLines.append(line)
            }
        }
        if !unreadableLines.isEmpty {
            Log.warn("\(unreadableLines.count) line(s) in \(jsonlURL.lastPathComponent) could not be decoded — kept verbatim")
        }
        records = loaded
        persistedIDs = Set(loaded.map(\.id))
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
        persistedIDs = Set(imported.map(\.id))
        rewriteDisk(imported)
        Log.info("Imported \(imported.count) dictations from the old Markdown history")
    }

    private func appendToDisk(_ record: DictationRecord) {
        guard let jsonlURL, let directory else { return }
        diskQueue.sync {
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
    }

    private func rewriteDisk(_ records: [DictationRecord]) {
        guard let jsonlURL else { return }
        lock.lock()
        let untrusted = diskIsUntrusted
        let keptVerbatim = unreadableLines
        lock.unlock()
        if untrusted {
            Log.warn("Not rewriting \(jsonlURL.lastPathComponent): it could not be read at launch")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = keptVerbatim + records.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        let md = "# Vocaret dictation history\n\n" + records.map { "- **\(Self.formatter.string(from: $0.date))** \($0.text)" }.joined(separator: "\n") + "\n"
        diskQueue.sync {
            try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: jsonlURL, atomically: true, encoding: .utf8)
            try? md.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
