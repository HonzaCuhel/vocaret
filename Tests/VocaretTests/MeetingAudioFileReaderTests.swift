import AVFoundation
import XCTest
import WhisperKit
@testable import VocaretCore

final class MeetingAudioFileReaderTests: XCTestCase {
    func testLongStereoFileIsDeliveredInBoundedMonoBlocks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let seconds = Double(ProcessInfo.processInfo.environment["VOCARET_AUDIO_BENCHMARK_SECONDS"] ?? "60") ?? 60
        try writeFixture(url, seconds: seconds, sampleRate: 48_000, channels: 2)
        let reader = try MeetingAudioFileReader(url: url)
        var total = 0
        var largest = 0
        while let samples = try reader.next() {
            total += samples.count
            largest = max(largest, samples.count)
            XCTAssertTrue(samples.allSatisfy { $0.isFinite })
        }
        XCTAssertEqual(Double(total) / 16_000, seconds, accuracy: 0.01)
        XCTAssertLessThanOrEqual(largest, 4_064)
        XCTAssertNil(try reader.next())
    }

    // Run in a separate XCTest process from the streaming test with time -l.
    // This deliberately retains the old loading path as a reproducible baseline.
    func testWholeFileMemoryBenchmarkBaseline() throws {
        guard let value = ProcessInfo.processInfo.environment["VOCARET_AUDIO_BENCHMARK_SECONDS"],
              let seconds = Double(value) else { throw XCTSkip("Opt-in synthetic memory benchmark") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(url, seconds: seconds, sampleRate: 48_000, channels: 2)
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        XCTAssertEqual(Double(samples.count) / 16_000, seconds, accuracy: 0.01)
    }

    func testShortFinalBlockIsNotLost() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(url, seconds: 0.3, sampleRate: 16_000, channels: 1)
        let reader = try MeetingAudioFileReader(url: url)
        var total = 0
        while let samples = try reader.next() { total += samples.count }
        XCTAssertEqual(total, 4_800)
    }

    func testCancellationStopsBeforeReadingMoreAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(url, seconds: 1, sampleRate: 16_000, channels: 1)
        let gate = expectation(description: "ready")
        let task = Task {
            let reader = try MeetingAudioFileReader(url: url)
            gate.fulfill()
            while !Task.isCancelled { await Task.yield() }
            return try reader.next()
        }
        await fulfillment(of: [gate], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled file processing must stop")
        } catch is CancellationError { }
    }

    private func writeFixture(_ url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                               channels: channels, interleaved: false))
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        var remaining = Int(seconds * sampleRate)
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, 4_800))
            for channel in 0..<Int(channels) {
                for frame in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![channel][frame] = 0.1 * sin(Float(frame) * 0.04)
                }
            }
            try file.write(from: buffer)
            remaining -= Int(buffer.frameLength)
        }
    }
}
