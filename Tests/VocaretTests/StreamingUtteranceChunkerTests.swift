import XCTest
@testable import VocaretCore

final class StreamingUtteranceChunkerTests: XCTestCase {
    private func audio(_ seconds: Double, _ amplitude: Float = 0) -> [Float] {
        [Float](repeating: amplitude, count: Int(seconds * 16_000))
    }

    func testEmitsDuringPauseBeforeFinishAndDoesNotRepeatAtFinish() {
        var chunker = StreamingUtteranceChunker()
        XCTAssertTrue(chunker.append(audio(1, 0.1)).isEmpty)
        let chunks = chunker.append(audio(1.5))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.startSample, 0)
        XCTAssertTrue(chunker.finish().isEmpty)
    }

    func testFinalShortWordIsNotLost() {
        var chunker = StreamingUtteranceChunker()
        XCTAssertTrue(chunker.append(audio(0.3, 0.1)).isEmpty)
        XCTAssertEqual(chunker.finish().count, 1)
        XCTAssertTrue(chunker.finish().isEmpty)
    }

    func testSilenceStaysBoundedAndLaterSpeechKeepsTimestamp() {
        var chunker = StreamingUtteranceChunker()
        for _ in 0..<600 { XCTAssertTrue(chunker.append(audio(1)).isEmpty) }
        XCTAssertLessThanOrEqual(chunker.bufferedSampleCount, 16_000)
        _ = chunker.append(audio(1, 0.1))
        let chunks = chunker.append(audio(1.5))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(Double(chunks[0].startSample) / 16_000, 599.75, accuracy: 0.1)
    }

    func testContinuousSpeechIsBoundedAndDoesNotOverlapOrLoseSamples() {
        var chunker = StreamingUtteranceChunker()
        var chunks: [MeetingAudioChunk] = []
        for _ in 0..<60 {
            chunks += chunker.append(audio(1, 0.1))
            XCTAssertLessThanOrEqual(chunker.bufferedSampleCount, 16_000 * 13)
        }
        XCTAssertFalse(chunks.isEmpty)
        chunks += chunker.finish()
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.samples.count }, 60 * 16_000)
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(pair.0.startSample + pair.0.samples.count, pair.1.startSample)
        }
    }

    func testSmallCallbacksMatchLargeCallbacks() {
        let samples = audio(1, 0.1) + audio(1.5) + audio(0.5, 0.2) + audio(1.5)
        var a = StreamingUtteranceChunker()
        var b = StreamingUtteranceChunker()
        let expected = a.append(samples) + a.finish()
        var actual: [MeetingAudioChunk] = []
        for start in stride(from: 0, to: samples.count, by: 137) {
            actual += b.append(Array(samples[start..<min(start + 137, samples.count)]))
        }
        actual += b.finish()
        XCTAssertEqual(actual.map(\.startSample), expected.map(\.startSample))
        XCTAssertEqual(actual.map(\.samples.count), expected.map(\.samples.count))
    }
}
