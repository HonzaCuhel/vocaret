import Foundation

struct RecordingActivitySnapshot: Sendable {
    let sampleCount: Int
    let sampleRate: Double
    let tail: [Float]
    let peakEnergy: Float

    var tailStartSample: Int { sampleCount - tail.count }
}

/// Small rolling view of a recording used by the pause watcher. The complete
/// audio remains in `MicRecorder`; this value keeps only a fixed-size tail and
/// streaming energy statistics so polling cost does not grow with duration.
struct RecordingActivity: Sendable {
    let sampleRate: Double

    private let maximumTailSamples: Int
    private let energyFrameLength: Int
    private var tail: [Float] = []
    private var frameSquareSum: Float = 0
    private var frameSampleCount = 0
    private(set) var sampleCount = 0
    private(set) var peakEnergy: Float = 0

    init(sampleRate: Double, maximumTailSeconds: Double = 2) {
        self.sampleRate = sampleRate
        maximumTailSamples = max(1, Int(sampleRate * maximumTailSeconds))
        energyFrameLength = max(1, Int(sampleRate * SpeechPause.frameSeconds))
        tail.reserveCapacity(maximumTailSamples)
    }

    mutating func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        sampleCount += samples.count

        for sample in samples {
            frameSquareSum += sample * sample
            frameSampleCount += 1
            if frameSampleCount == energyFrameLength {
                peakEnergy = max(peakEnergy, (frameSquareSum / Float(energyFrameLength)).squareRoot())
                frameSquareSum = 0
                frameSampleCount = 0
            }
        }

        tail.append(contentsOf: samples)
        if tail.count > maximumTailSamples {
            tail.removeFirst(tail.count - maximumTailSamples)
        }
    }

    func snapshot(tailSeconds: Double) -> RecordingActivitySnapshot {
        let requestedCount = max(0, Int(sampleRate * tailSeconds))
        let keptCount = min(requestedCount, tail.count)
        return RecordingActivitySnapshot(
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            tail: Array(tail.suffix(keptCount)),
            peakEnergy: peakEnergy
        )
    }
}
