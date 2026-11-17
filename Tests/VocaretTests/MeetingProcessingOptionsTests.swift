import XCTest
@testable import VocaretCore

final class MeetingProcessingOptionsTests: XCTestCase {
    func testCloudNotesAreSelectedEvenWhenDictationCleanupIsOff() {
        let name = "VocaretMeetingOptions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.cleanDictation = false
        settings.cleanMeetings = true
        settings.dictationCleanupModel = "gpt-5-nano"
        settings.asrEngine = "soniox"
        let options = MeetingProcessingOptions(settings: settings)
        XCTAssertEqual(options.notesProvider, .gpt5Nano)
        XCTAssertFalse(options.shouldWarmLocalNotes)
        XCTAssertTrue(options.usesCloudSpeech)
        settings.dictationCleanupModel = "local"
        settings.asrEngine = "whisper"
        XCTAssertEqual(options.notesProvider, .gpt5Nano, "A meeting snapshots its selected provider")
        XCTAssertEqual(options.speechEngine, "soniox")
    }

    func testDisablingNotesNeverWarmsLocalModel() {
        let name = "VocaretMeetingOptions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.cleanMeetings = false
        settings.dictationCleanupModel = "local"
        XCTAssertFalse(MeetingProcessingOptions(settings: settings).shouldWarmLocalNotes)
        settings.cleanMeetings = true
        XCTAssertTrue(MeetingProcessingOptions(settings: settings).shouldWarmLocalNotes)
    }
}
