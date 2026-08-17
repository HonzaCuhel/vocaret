import Foundation

/// Splits 16 kHz mono audio into utterance-sized chunks at silences.
///
/// Why: Whisper applies ONE language token per 30-second window, so a window
/// containing both Czech and English drops or silently translates one of them.
/// Transcribing utterance by utterance (each with its own language detection)
/// makes bilingual meetings robust. Pure function — unit-tested.
public struct UtteranceChunker {
    public var sampleRate: Double = 16_000
    /// Analysis frame length for the energy VAD.
    public var frameSeconds: Double = 0.05
    /// Silences shorter than this stay inside the same chunk. Turn-taking
    /// pauses in calls are usually ≥ 0.8 s; intra-sentence pauses are shorter.
    public var mergeGapSeconds: Double = 0.8
    /// Hard cap; longer speech is split at its quietest frame near the cap.
    public var maxChunkSeconds: Double = 25.0
    /// Speech bursts shorter than this are noise/blips and are dropped.
    public var minChunkSeconds: Double = 0.4
    /// Context added on both sides of each chunk (never past the audio bounds).
    public var paddingSeconds: Double = 0.25
    /// Absolute RMS floor below which nothing counts as speech.
    public var absoluteThreshold: Float = 0.0015
    /// Threshold relative to the loudest frame — adapts to quiet microphones.
    public var relativeThreshold: Float = 0.05

    public init() {}

    /// Sample ranges (into `samples`) of speech chunks, in order.
    public func chunks(in samples: [Float]) -> [Range<Int>] {
        guard !samples.isEmpty else { return [] }
        let frameLength = max(1, Int(frameSeconds * sampleRate))
        let frameCount = (samples.count + frameLength - 1) / frameLength

        // 1. Per-frame RMS energy.
        var rms = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let start = frame * frameLength
            let end = min(start + frameLength, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            rms[frame] = (sum / Float(end - start)).squareRoot()
        }
        guard let loudest = rms.max(), loudest > absoluteThreshold else { return [] }
        let threshold = max(absoluteThreshold, loudest * relativeThreshold)

        // 2. Active frame runs → regions (in frames).
        var regions: [Range<Int>] = []
        var runStart: Int?
        for (index, energy) in rms.enumerated() {
            if energy >= threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                regions.append(start..<index)
                runStart = nil
            }
        }
        if let start = runStart { regions.append(start..<frameCount) }

        // 3. Merge regions separated by short gaps.
        let mergeGapFrames = Int(mergeGapSeconds / frameSeconds)
        var merged: [Range<Int>] = []
        for region in regions {
            if let last = merged.last, region.lowerBound - last.upperBound < mergeGapFrames {
                merged[merged.count - 1] = last.lowerBound..<region.upperBound
            } else {
                merged.append(region)
            }
        }

        // 4. Split over-long regions at the quietest frame in the back half of the cap window.
        let maxFrames = Int(maxChunkSeconds / frameSeconds)
        var capped: [Range<Int>] = []
        for region in merged {
            var current = region
            while current.count > maxFrames {
                let searchStart = current.lowerBound + maxFrames / 2
                let searchEnd = current.lowerBound + maxFrames
                var cut = searchEnd
                var quietest = Float.greatestFiniteMagnitude
                for frame in searchStart..<searchEnd where rms[frame] < quietest {
                    quietest = rms[frame]
                    cut = frame
                }
                capped.append(current.lowerBound..<cut)
                current = cut..<current.upperBound
            }
            capped.append(current)
        }

        // 5. Drop blips, pad, convert to sample ranges.
        let minFrames = Int(minChunkSeconds / frameSeconds)
        let paddingSamples = Int(paddingSeconds * sampleRate)
        return capped
            .filter { $0.count >= minFrames }
            .map { region in
                let start = max(0, region.lowerBound * frameLength - paddingSamples)
                let end = min(samples.count, region.upperBound * frameLength + paddingSamples)
                return start..<end
            }
    }
}
