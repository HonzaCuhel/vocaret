import XCTest
@testable import VocaretCore

/// The early-transcription decision: it must fire on a real pause, never on a
/// gap between words, and never hand back a transcript that missed speech.
final class SpeechPauseTests: XCTestCase {
    private let rate = MicRecorder.whisperSampleRate

    private func speech(_ seconds: Double) -> [Float] {
        let count = Int(seconds * rate)
        // A 200 Hz tone at speech-like amplitude.
        return (0..<count).map { 0.3 * sin(Float($0) * 2 * .pi * 200 / Float(rate)) }
    }
    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    func testFiresAfterARealPause() {
        // 0.6 s is what a recording holds when someone stops talking and then
        // lets go of the key — it must fire there, not only at a luxurious 1 s.
        let samples = speech(2.0) + silence(0.6)
        XCTAssertTrue(SpeechPause.shouldSpeculate(on: samples, alreadySpeculatedCount: 0))
        XCTAssertEqual(SpeechPause.trailingSilence(in: samples) ?? 0, 0.6, accuracy: 0.06)
    }

    func testDoesNotFireBetweenWords() {
        // A 0.2 s gap is a breath, not the end of a thought.
        let samples = speech(2.0) + silence(0.2)
        XCTAssertFalse(SpeechPause.shouldSpeculate(on: samples, alreadySpeculatedCount: 0))
    }

    func testDoesNotFireWhileStillSpeaking() {
        XCTAssertFalse(SpeechPause.shouldSpeculate(on: speech(3.0), alreadySpeculatedCount: 0))
    }

    func testDoesNotFireOnSilenceOnlyOrTinyClips() {
        XCTAssertFalse(SpeechPause.shouldSpeculate(on: silence(3.0), alreadySpeculatedCount: 0))
        XCTAssertFalse(SpeechPause.shouldSpeculate(on: speech(0.3) + silence(0.5), alreadySpeculatedCount: 0))
    }

    func testDoesNotSpeculateTwiceOnTheSamePause() {
        let samples = speech(2.0) + silence(0.6)
        XCTAssertFalse(SpeechPause.shouldSpeculate(on: samples, alreadySpeculatedCount: samples.count))
    }

    func testDoesNotSpeculateAgainWhenOnlyMoreSilenceWasCaptured() {
        let first = speech(2.0) + silence(0.6)
        let later = first + silence(0.5)
        XCTAssertFalse(SpeechPause.shouldSpeculate(on: later, alreadySpeculatedCount: first.count))
    }

    func testActivitySnapshotDetectsPauseWithoutCopyingWholeRecording() {
        var activity = RecordingActivity(sampleRate: rate, maximumTailSeconds: 1.5)
        activity.append(speech(4.0))
        activity.append(silence(0.6))

        XCTAssertTrue(SpeechPause.shouldSpeculate(
            on: activity.snapshot(tailSeconds: 1.5),
            alreadySpeculatedCount: 0
        ))
    }

    func testSpeculatesAgainAfterMoreSpeechAndAnotherPause() {
        let first = speech(2.0) + silence(0.6)
        let second = first + speech(1.5) + silence(0.6)
        XCTAssertTrue(SpeechPause.shouldSpeculate(on: second, alreadySpeculatedCount: first.count))
    }

    // MARK: - Is the early transcript still complete?

    func testEarlyTranscriptIsUsedWhenOnlySilenceFollowed() {
        let early = speech(2.0) + silence(0.6)
        let final = early + silence(0.4) // user just let go of the key
        XCTAssertTrue(SpeechPause.covers(early.count, of: final))
    }

    func testEarlyTranscriptIsRejectedWhenSpeechFollowed() {
        // The dangerous case: the user paused, we decoded, then they carried on.
        let early = speech(2.0) + silence(0.6)
        let final = early + speech(1.5) + silence(0.3)
        XCTAssertFalse(SpeechPause.covers(early.count, of: final))
    }

    func testTrailingSilenceIsNilWithoutSpeech() {
        XCTAssertNil(SpeechPause.trailingSilence(in: silence(2.0)))
    }

    func testQuietSpeechAfterTheEarlyDecodeIsStillNoticed() {
        // The tail is quieter than the rest; it must not be mistaken for silence
        // or the user loses the end of their sentence.
        let loud = speech(2.0)
        let quiet = speech(1.0).map { $0 * 0.2 }
        let early = loud + silence(0.6)
        XCTAssertFalse(SpeechPause.covers(early.count, of: early + quiet))
    }
}
