import Foundation

/// Speaker IDs belong to one Soniox connection; they are not names or identities
/// that can be matched across separate audio tracks or meetings. Times are seconds
/// from the beginning of the audio sent on that connection.
struct SonioxDiarizedSegment: Equatable, Sendable {
    let speakerID: String?
    let start: Double
    let end: Double
    let text: String
}

struct SonioxDiarizationAccumulator: Sendable {
    private var committed = SegmentBuilder()
    private var tentativeTokens: [SonioxToken] = []

    var finalizedSegments: [SonioxDiarizedSegment] { committed.snapshot }

    var visibleSegments: [SonioxDiarizedSegment] {
        var visible = committed
        for token in tentativeTokens { visible.append(token) }
        return visible.snapshot
    }

    mutating func consume(_ response: SonioxResponse) {
        // Final tokens arrive once and cannot change. Every response replaces
        // the complete non-final suffix, including any tentative speaker IDs.
        tentativeTokens.removeAll(keepingCapacity: true)
        for token in response.tokens {
            guard token.text != "<end>", token.text != "<fin>" else { continue }
            if token.isFinal {
                committed.append(token)
            } else {
                tentativeTokens.append(token)
            }
        }
    }

    private struct SegmentBuilder: Sendable {
        // Keep original token spacing here, including leading spaces. Trimming
        // happens only on snapshots so appending a later subword stays lossless.
        private var segments: [SonioxDiarizedSegment] = []

        var snapshot: [SonioxDiarizedSegment] {
            segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return SonioxDiarizedSegment(speakerID: segment.speakerID, start: segment.start,
                                             end: segment.end, text: text)
            }
        }

        mutating func append(_ token: SonioxToken) {
            guard !token.text.isEmpty else { return }
            let speaker = token.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            let speakerID = speaker.flatMap { $0.isEmpty ? nil : $0 }
            // Older/partial payloads may omit timing. Preserve their text at the
            // last known boundary instead of dropping it or inventing duration.
            let start = max(0, seconds(token.startMS) ?? segments.last?.end ?? 0)
            let end = max(start, seconds(token.endMS) ?? start)
            if let previous = segments.last,
               previous.speakerID == speakerID,
               start - previous.end <= 1.5 {
                segments[segments.count - 1] = SonioxDiarizedSegment(
                    speakerID: speakerID,
                    start: min(previous.start, start),
                    end: max(previous.end, end),
                    text: previous.text + token.text
                )
            } else {
                segments.append(SonioxDiarizedSegment(speakerID: speakerID, start: start,
                                                     end: end, text: token.text))
            }
        }

        private func seconds(_ milliseconds: Double?) -> Double? {
            guard let milliseconds, milliseconds.isFinite else { return nil }
            return milliseconds / 1_000
        }
    }
}
