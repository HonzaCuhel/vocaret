import Foundation

struct MeetingAudioChunk: Sendable {
    let startSample: Int
    let samples: [Float]
}

/// Runs the same bilingual VAD as file transcription, but only over a bounded
/// tail. Complete utterances leave the buffer once; the unfinished word stays.
struct StreamingUtteranceChunker: Sendable {
    private var samples: [Float] = []
    private var offset = 0
    private var untilAnalysis = 4_000 // 250 ms, independent of callback size
    var bufferedSampleCount: Int { samples.count }

    mutating func append(_ input: [Float]) -> [MeetingAudioChunk] {
        var result: [MeetingAudioChunk] = []
        var index = 0
        while index < input.count {
            let count = min(untilAnalysis, input.count - index)
            samples.append(contentsOf: input[index..<index + count])
            index += count
            untilAnalysis -= count
            if untilAnalysis == 0 {
                result += drain(final: false)
                untilAnalysis = 4_000
            }
        }
        return result
    }

    mutating func finish() -> [MeetingAudioChunk] { drain(final: true) }

    private mutating func drain(final: Bool) -> [MeetingAudioChunk] {
        var vad = UtteranceChunker()
        vad.maxChunkSeconds = 12
        let ranges = vad.chunks(in: samples)
        // The last region needs a full turn-taking pause. Earlier regions have
        // already ended at silence or at a hard split in sustained speech.
        let ready = ranges.enumerated().filter { index, range in
            final || index < ranges.count - 1 || samples.count - range.upperBound >= 12_800
        }.map(\.element)
        let chunks = ready.map { MeetingAudioChunk(startSample: offset + $0.lowerBound, samples: Array(samples[$0])) }
        let consumed: Int
        if final {
            consumed = samples.count
        } else if let last = ready.last {
            consumed = last.upperBound
        } else if ranges.isEmpty {
            // Retain even sub-minimum speech at the edge for the next callback.
            consumed = max(0, samples.count - 16_000)
        } else {
            consumed = 0
        }
        if consumed > 0 {
            samples.removeFirst(consumed)
            offset += consumed
        }
        return chunks
    }
}
