import Foundation

/// Decides, from the audio captured so far, whether the speaker has paused long
/// enough that it is worth transcribing early — and afterwards whether that
/// early transcript still covers everything they said.
///
/// Pure and cheap (one RMS pass), so it can run every few hundred milliseconds
/// while the hotkey is held. It measures silence directly rather than going
/// through `UtteranceChunker`, whose 0.25 s padding and 0.8 s merge gap are
/// meant for splitting long recordings and would hide exactly the pauses this
/// needs to see.
public enum SpeechPause {
    /// Trailing silence that counts as "finished a thought". Long enough not to
    /// fire between words, short enough that the decode is usually done by the
    /// time the key comes up.
    public static let endOfSpeechSilence = 0.5
    /// Below this there is not enough audio for an early decode to pay for itself.
    public static let minimumSpeculationSeconds = 1.0

    static let frameSeconds = 0.05
    /// Silence in a quiet room; below this nothing counts as speech however the
    /// rest of the clip is scaled. Matches `UtteranceChunker`.
    static let absoluteThreshold: Float = 0.0015
    /// A frame counts as speech at this fraction of the clip's loudest frame.
    static let relativeThreshold: Float = 0.06

    /// Root-mean-square energy per fixed-length frame.
    static func frameEnergies(_ samples: [Float], sampleRate: Double) -> [Float] {
        let frameLength = max(1, Int(frameSeconds * sampleRate))
        let frameCount = samples.count / frameLength
        guard frameCount > 0 else { return [] }
        var energies = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let start = frame * frameLength
            var sum: Float = 0
            for index in start..<(start + frameLength) { sum += samples[index] * samples[index] }
            energies[frame] = (sum / Float(frameLength)).squareRoot()
        }
        return energies
    }

    /// The energy above which a frame counts as speech, calibrated on the
    /// loudest frame so a quiet mic still works. Nil when the clip is silent.
    static func speechThreshold(_ energies: [Float]) -> Float? {
        guard let peak = energies.max(), peak > absoluteThreshold else { return nil }
        return max(absoluteThreshold, peak * relativeThreshold)
    }

    /// Seconds of silence at the end of `samples`, or nil when no speech has
    /// been detected at all yet.
    public static func trailingSilence(in samples: [Float], sampleRate: Double = MicRecorder.whisperSampleRate) -> Double? {
        let energies = frameEnergies(samples, sampleRate: sampleRate)
        guard let threshold = speechThreshold(energies),
              let lastSpeech = energies.lastIndex(where: { $0 > threshold }) else { return nil }
        let speechEnd = Double(lastSpeech + 1) * frameSeconds
        return max(0, Double(samples.count) / sampleRate - speechEnd)
    }

    /// True when it is worth starting a transcription of `samples` now.
    /// `alreadySpeculatedCount` is the sample count of the last early decode, so
    /// the same pause is not decoded twice.
    public static func shouldSpeculate(
        on samples: [Float],
        alreadySpeculatedCount: Int,
        sampleRate: Double = MicRecorder.whisperSampleRate
    ) -> Bool {
        guard Double(samples.count) / sampleRate >= minimumSpeculationSeconds else { return false }
        guard samples.count > alreadySpeculatedCount else { return false }
        guard let silence = trailingSilence(in: samples, sampleRate: sampleRate) else { return false }
        return silence >= endOfSpeechSilence
    }

    /// True when a transcript covering the first `speculatedCount` samples still
    /// covers everything: the audio recorded after it must be silence, or the
    /// user said something the early decode never heard. The threshold is
    /// calibrated on the whole clip, so speech quieter than the rest still counts.
    public static func covers(
        _ speculatedCount: Int,
        of finalSamples: [Float],
        sampleRate: Double = MicRecorder.whisperSampleRate
    ) -> Bool {
        guard finalSamples.count >= speculatedCount else { return false }
        let energies = frameEnergies(finalSamples, sampleRate: sampleRate)
        guard let threshold = speechThreshold(energies) else { return true } // all silence
        let frameLength = max(1, Int(frameSeconds * sampleRate))
        let firstTailFrame = speculatedCount / frameLength
        guard firstTailFrame < energies.count else { return true }
        return !energies[firstTailFrame...].contains { $0 > threshold }
    }
}
