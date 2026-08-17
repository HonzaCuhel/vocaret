import Foundation

/// A timestamped piece of recognized speech from one audio track.
public struct SpokenSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum Speaker: Equatable, Sendable {
    case me
    case them

    public var label: String {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        }
    }
}

/// A contiguous run of speech by one speaker after merging both tracks.
public struct MergedTurn: Equatable, Sendable {
    public var speaker: Speaker
    public var start: Double
    public var text: String

    public init(speaker: Speaker, start: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.text = text
    }
}

/// Combines the microphone track ("Me") and the system-audio track ("Them")
/// into one chronological transcript.
public enum TranscriptMerger {

    /// Consecutive segments by the same speaker separated by less than
    /// `coalesceGap` seconds collapse into a single turn.
    public static func merge(
        mine: [SpokenSegment],
        theirs: [SpokenSegment],
        coalesceGap: Double = 2.0
    ) -> [MergedTurn] {
        var tagged: [(speaker: Speaker, segment: SpokenSegment)] = []
        for segment in mine {
            tagged.append((.me, segment))
        }
        for segment in theirs {
            tagged.append((.them, segment))
        }

        let ordered = tagged
            .map { (speaker: $0.speaker, segment: trimmed($0.segment)) }
            .filter { !$0.segment.text.isEmpty }
            .sorted { $0.segment.start < $1.segment.start }

        var turns: [MergedTurn] = []
        var currentEnd = 0.0
        for (speaker, segment) in ordered {
            if var last = turns.last,
               last.speaker == speaker,
               segment.start - currentEnd <= coalesceGap {
                last.text += " " + segment.text
                turns[turns.count - 1] = last
            } else {
                turns.append(MergedTurn(speaker: speaker, start: segment.start, text: segment.text))
            }
            currentEnd = max(currentEnd, segment.end)
        }
        return turns
    }

    public static func markdown(turns: [MergedTurn]) -> String {
        turns
            .map { "**\($0.speaker.label) [\(timestamp($0.start))]:** \($0.text)" }
            .joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func trimmed(_ segment: SpokenSegment) -> SpokenSegment {
        var copy = segment
        copy.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}
