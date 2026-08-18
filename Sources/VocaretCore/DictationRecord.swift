import Foundation

/// One dictation, with enough metadata to compute speed and productivity
/// metrics later. Stored as JSON Lines in `dictation-history.jsonl`.
public struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var text: String
    /// How long the microphone was open.
    public var recordingSeconds: Double
    /// How long Whisper (and cleanup, if any) took after release.
    public var transcriptionSeconds: Double
    public var model: String
    public var cleaned: Bool

    public init(id: UUID = UUID(), date: Date, text: String, recordingSeconds: Double,
                transcriptionSeconds: Double, model: String, cleaned: Bool = false) {
        self.id = id
        self.date = date
        self.text = text
        self.recordingSeconds = recordingSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.model = model
        self.cleaned = cleaned
    }

    public var wordCount: Int { Self.wordCount(of: text) }

    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Words per minute of *speaking* (not typing).
    public var wordsPerMinute: Double {
        guard recordingSeconds > 0 else { return 0 }
        return Double(wordCount) / (recordingSeconds / 60)
    }
}
