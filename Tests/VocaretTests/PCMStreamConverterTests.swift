import AVFoundation
import XCTest
@testable import VocaretCore

final class PCMStreamConverterTests: XCTestCase {
    func testConvertsStereoSystemAudioToBoundedMonoStream() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 2, interleaved: true))
        let converter = try PCMStreamConverter(format: format)
        var converted: [Float] = []
        for _ in 0..<100 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            buffer.frameLength = 480
            let data = try XCTUnwrap(buffer.floatChannelData)[0]
            for i in 0..<960 { data[i] = 0.2 }
            converted += try converter.convert(buffer)
        }
        XCTAssertEqual(Double(converted.count), 16_000, accuracy: 64)
        XCTAssertTrue(converted.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(converted.map(abs).max() ?? 0, 0.1)
    }

    func testConverts44100HzMonoWithoutAccumulatingRoundingDrift() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100, channels: 1, interleaved: false))
        let converter = try PCMStreamConverter(format: format)
        var count = 0
        for _ in 0..<200 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441))
            buffer.frameLength = 441
            let data = try XCTUnwrap(buffer.floatChannelData)[0]
            for i in 0..<441 { data[i] = 0.1 }
            count += try converter.convert(buffer).count
        }
        XCTAssertEqual(Double(count), 32_000, accuracy: 64)
    }
}
