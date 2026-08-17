import XCTest
@testable import VocaretCore

final class UtteranceChunkerTests: XCTestCase {
    private let rate = 16_000
    private let chunker = UtteranceChunker()

    /// Synthetic "speech": a 200 Hz tone at the given amplitude.
    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { i in
            amplitude * sinf(Float(i) * 2 * .pi * 200 / Float(rate))
        }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    private func seconds(_ range: Range<Int>) -> (Double, Double) {
        (Double(range.lowerBound) / Double(rate), Double(range.upperBound) / Double(rate))
    }

    func testSilenceYieldsNoChunks() {
        XCTAssertTrue(chunker.chunks(in: silence(seconds: 5)).isEmpty)
        XCTAssertTrue(chunker.chunks(in: []).isEmpty)
    }

    func testTwoUtterancesSeparatedByLongPauseBecomeTwoChunks() {
        let audio = tone(seconds: 3) + silence(seconds: 2.5) + tone(seconds: 2)
        let chunks = chunker.chunks(in: audio)

        XCTAssertEqual(chunks.count, 2)
        let (s0, e0) = seconds(chunks[0])
        let (s1, e1) = seconds(chunks[1])
        XCTAssertEqual(s0, 0, accuracy: 0.3)
        XCTAssertEqual(e0, 3, accuracy: 0.4)
        XCTAssertEqual(s1, 5.5, accuracy: 0.4)
        XCTAssertEqual(e1, 7.5, accuracy: 0.3)
    }

    func testShortPauseKeepsUtterancesInOneChunk() {
        let audio = tone(seconds: 3) + silence(seconds: 0.4) + tone(seconds: 2)
        XCTAssertEqual(chunker.chunks(in: audio).count, 1)
    }

    func testLongContinuousSpeechIsSplitBelowMaxChunk() {
        let audio = tone(seconds: 70)
        let chunks = chunker.chunks(in: audio)

        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(Double(chunk.count) / Double(rate), chunker.maxChunkSeconds + 0.6)
        }
        // Chunks tile the speech: consecutive, non-overlapping beyond padding, covering start and end.
        XCTAssertEqual(chunks.first!.lowerBound, 0)
        XCTAssertEqual(chunks.last!.upperBound, audio.count)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertLessThanOrEqual(a.upperBound, b.lowerBound + Int(chunker.paddingSeconds * 2 * Double(rate)) + 1)
        }
    }

    func testTinyBlipsAreDropped() {
        let audio = silence(seconds: 1) + tone(seconds: 0.08) + silence(seconds: 3)
        XCTAssertTrue(chunker.chunks(in: audio).isEmpty)
    }

    /// A single short word must survive: at the previous 0.4 s floor, dictating
    /// "Ano." produced no chunks and the transcript was silently discarded.
    func testSingleShortWordIsKept() {
        for spokenLength in [0.25, 0.35, 0.5] {
            let audio = silence(seconds: 0.3) + tone(seconds: spokenLength) + silence(seconds: 0.3)
            XCTAssertEqual(chunker.chunks(in: audio).count, 1, "\(spokenLength)s word was dropped")
        }
    }

    /// Splitting a long region must not hand the same audio to two chunks —
    /// padding both sides of a cut duplicated 0.5 s and words were transcribed twice.
    func testCapSplitsDoNotOverlap() {
        let chunks = chunker.chunks(in: tone(seconds: 70))
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertLessThanOrEqual(a.upperBound, b.lowerBound, "chunks overlap: \(a) then \(b)")
        }
    }

    /// One loud transient must not raise the threshold so far that speech is lost.
    func testLoudTransientDoesNotSuppressQuietSpeech() {
        let bang = [Float](repeating: 0.99, count: 800) // 50 ms slam
        let audio = bang + silence(seconds: 1.5) + tone(seconds: 2, amplitude: 0.05)
        let chunks = chunker.chunks(in: audio)
        // The quiet speech after the bang must still be found.
        XCTAssertTrue(chunks.contains { Double($0.upperBound) / 16_000 > 2.0 },
                      "quiet speech was suppressed by the transient; chunks=\(chunks)")
    }

    func testQuietSpeechIsStillDetectedRelativeToItsOwnLevel() {
        // Whole file quiet (peak 0.03, like a distant mic) — threshold must adapt.
        let audio = tone(seconds: 2, amplitude: 0.03) + silence(seconds: 2) + tone(seconds: 2, amplitude: 0.03)
        XCTAssertEqual(chunker.chunks(in: audio).count, 2)
    }

    func testRangesAreWithinBounds() {
        let audio = tone(seconds: 1) + silence(seconds: 2) + tone(seconds: 1)
        for chunk in chunker.chunks(in: audio) {
            XCTAssertGreaterThanOrEqual(chunk.lowerBound, 0)
            XCTAssertLessThanOrEqual(chunk.upperBound, audio.count)
            XCTAssertLessThan(chunk.lowerBound, chunk.upperBound)
        }
    }
}
