import XCTest
@testable import VocaretCore

@MainActor
final class MeetingRecordingNameTests: XCTestCase {
    func testImmediateRestartCannotOverwriteAudioKeptForRecovery() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = MeetingController.makeRecordingStem(at: date)
        let second = MeetingController.makeRecordingStem(at: date)
        XCTAssertNotEqual(first, second)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstAudio = directory.appendingPathComponent(first + "-mic.wav")
        let secondAudio = directory.appendingPathComponent(second + "-mic.wav")
        try Data([1, 2, 3]).write(to: firstAudio)
        try Data([4, 5, 6]).write(to: secondAudio)
        XCTAssertEqual(try Data(contentsOf: firstAudio), Data([1, 2, 3]))
    }
}
