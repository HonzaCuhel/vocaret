import Foundation

/// Words Vocaret should always spell your way — product names, jargon, people —
/// plus corrections it has learned from watching the AI cleanup fix the same
/// word twice.
///
/// Two sources, both plain files the user can edit:
/// - `vocabulary.txt` — one term per line, `#` for comments
/// - `learned-corrections.json` — `{"wrong": {"to": "Right", "count": N}}`
public final class Vocabulary: @unchecked Sendable {
    public static let shared = Vocabulary(persistence: SettingsStore.shared.appSupportDir)

    /// A correction must be seen this many times before it is applied on its
    /// own — one occurrence could easily be the LLM paraphrasing.
    public static let learningThreshold = 2

    private let lock = NSLock()
    private let directory: URL?
    private var _terms: [String] = []
    private var counted: [String: (to: String, count: Int)] = [:]
    /// Words the cleanup has left UNCHANGED at least once — i.e. real words the
    /// LLM only sometimes rewrites for grammar/agreement. Never learned.
    private var vetoed: Set<String> = []

    public init(persistence directory: URL?) {
        self.directory = directory
        load()
    }

    // MARK: - Contents

    public var terms: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _terms }
        set { lock.lock(); _terms = newValue; lock.unlock() }
    }

    /// Corrections trusted enough to apply automatically.
    public var learnedCorrections: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return counted
            .filter { $0.value.count >= Self.learningThreshold }
            .mapValues { $0.to }
    }

    public func addTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        if !_terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            _terms.append(trimmed)
        }
        lock.unlock()
        save()
    }

    /// Trust a correction immediately (used by tests and by explicit user action).
    public func forceLearn(wrong: String, right: String) {
        lock.lock()
        counted[wrong.lowercased()] = (right, Self.learningThreshold)
        lock.unlock()
    }

    // MARK: - Learning

    /// Compare what was transcribed with what the cleanup produced and remember
    /// single-word substitutions. Only same-length rewrites are considered, so
    /// a filler-word deletion cannot poison the mapping.
    public func learn(from original: String, to cleaned: String) {
        let before = original.split(separator: " ").map(String.init)
        let after = cleaned.split(separator: " ").map(String.init)
        guard before.count == after.count, !before.isEmpty else { return }

        var changed = false
        lock.lock()
        var previousEndedSentence = true // position 0 counts as sentence start
        for (rawBefore, rawAfter) in zip(before, after) {
            let wrong = Self.strip(rawBefore)
            let right = Self.strip(rawAfter)
            let sentenceStart = previousEndedSentence
            previousEndedSentence = rawAfter.last.map { ".!?…".contains($0) } ?? false
            guard !wrong.isEmpty else { continue }
            let key = wrong.lowercased()
            // Left alone by the cleanup → it is a real word; a rewrite of it
            // elsewhere is grammar (byli/byly), not spelling. Veto for good.
            if wrong == right {
                if counted[key] != nil || vetoed.contains(key) { vetoed.insert(key); counted[key] = nil; changed = true }
                continue
            }
            guard !vetoed.contains(key) else { continue }
            guard Self.isPlausibleCorrection(wrong: wrong, right: right) else { continue }
            // Sentence-initial capitalisation is punctuation work, not a spelling.
            if sentenceStart, wrong.lowercased() == right.lowercased() { continue }
            let existing = counted[key]
            if let existing, existing.to == right {
                counted[key] = (right, existing.count + 1)
            } else if existing == nil {
                counted[key] = (right, 1)
            } else {
                // Disagreeing correction — restart the count for the new target.
                counted[key] = (right, 1)
            }
            changed = true
        }
        lock.unlock()
        if changed { save() }
    }

    /// Guards against learning nonsense: the two words must be recognisably the
    /// same word (a casing/diacritic/typo variant), not a different one.
    static func isPlausibleCorrection(wrong: String, right: String) -> Bool {
        guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return false }
        guard wrong.rangeOfCharacter(from: .letters) != nil,
              right.rangeOfCharacter(from: .letters) != nil else { return false }
        // Pure casing change is always plausible ("whisper" -> "Whisper").
        if wrong.lowercased() == right.lowercased() { return true }
        // Otherwise require a small edit distance relative to the word length.
        let distance = TranscriptCorrector.editDistance(wrong.lowercased(), right.lowercased())
        let longer = max(wrong.count, right.count)
        guard longer >= 4 else { return false }
        return distance <= max(1, longer / 4)
    }

    private static func strip(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    // MARK: - Persistence

    private var vocabularyFile: URL? { directory?.appendingPathComponent("vocabulary.txt") }
    private var correctionsFile: URL? { directory?.appendingPathComponent("learned-corrections.json") }

    public var vocabularyFileURL: URL? { vocabularyFile }

    private func load() {
        if let vocabularyFile, let text = try? String(contentsOf: vocabularyFile, encoding: .utf8) {
            _terms = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        if let correctionsFile, let data = try? Data(contentsOf: correctionsFile) {
            if let stored = try? JSONDecoder().decode(StoredCorrections.self, from: data) {
                counted = stored.corrections.mapValues { (to: $0.to, count: $0.count) }
                vetoed = Set(stored.vetoed)
            } else if let raw = try? JSONDecoder().decode([String: StoredCorrection].self, from: data) {
                counted = raw.mapValues { (to: $0.to, count: $0.count) } // pre-veto file format
            }
        }
    }

    private struct StoredCorrection: Codable {
        let to: String
        let count: Int
    }

    private struct StoredCorrections: Codable {
        var corrections: [String: StoredCorrection]
        var vetoed: [String]
    }

    public func save() {
        lock.lock()
        let terms = _terms
        let stored = StoredCorrections(
            corrections: counted.mapValues { StoredCorrection(to: $0.to, count: $0.count) },
            vetoed: Array(vetoed).sorted()
        )
        lock.unlock()

        if let vocabularyFile {
            let header = """
            # Words Vocaret should always spell this way — one per line.
            # Product names, jargon, names of people. Lines starting with # are ignored.
            # Vocaret also learns corrections on its own; those live in
            # learned-corrections.json next to this file.

            """
            try? (header + terms.joined(separator: "\n") + "\n")
                .write(to: vocabularyFile, atomically: true, encoding: .utf8)
        }
        if let correctionsFile, let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: correctionsFile, options: .atomic)
        }
    }
}
