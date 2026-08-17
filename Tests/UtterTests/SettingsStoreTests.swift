import XCTest
@testable import UtterCore

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var suiteDefaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "UtterTests-\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: suiteDefaults)
    }

    override func tearDown() {
        suiteDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaults() {
        XCTAssertEqual(store.language, "auto")
        XCTAssertEqual(store.autoLanguages, ["cs", "en"])
        XCTAssertEqual(store.whisperModel, SettingsStore.defaultWhisperModel)
        XCTAssertFalse(store.cleanDictation)
        XCTAssertTrue(store.cleanMeetings)
        XCTAssertFalse(store.keepRecordings) // other people's voices are not kept by default
        XCTAssertTrue(store.keepModelLoaded)
        XCTAssertEqual(store.dictationKeyCode, 2) // D — not Space (macOS input-source switch)
        XCTAssertEqual(store.dictationModifiers, 0x1800) // control | option
        XCTAssertEqual(store.meetingKeyCode, 46)
        XCTAssertEqual(store.meetingModifiers, 0x1800)
        XCTAssertEqual(store.dictationHotkeyLabel, "⌃⌥D")
        XCTAssertEqual(store.meetingHotkeyLabel, "⌃⌥M")
        XCTAssertNil(store.llamaServerPath)
        XCTAssertNil(store.llmModelPath)
        XCTAssertEqual(store.llmPort, 8765)
    }

    func testRoundTrip() {
        store.language = "cs"
        store.autoLanguages = ["en"]
        store.cleanDictation = true
        store.cleanMeetings = false
        store.keepRecordings = true
        store.whisperModel = "openai_whisper-small"
        store.dictationKeyCode = 11
        store.dictationModifiers = 0x100
        store.llamaServerPath = "/opt/homebrew/bin/llama-server"
        store.llmModelPath = "/tmp/model.gguf"
        store.llmPort = 9999

        // Read through a fresh store over the same suite to prove persistence.
        let reread = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reread.language, "cs")
        XCTAssertEqual(reread.autoLanguages, ["en"])
        XCTAssertTrue(reread.cleanDictation)
        XCTAssertFalse(reread.cleanMeetings)
        XCTAssertTrue(reread.keepRecordings)
        XCTAssertEqual(reread.whisperModel, "openai_whisper-small")
        XCTAssertEqual(reread.dictationKeyCode, 11)
        XCTAssertEqual(reread.dictationModifiers, 0x100)
        XCTAssertEqual(reread.llamaServerPath, "/opt/homebrew/bin/llama-server")
        XCTAssertEqual(reread.llmModelPath, "/tmp/model.gguf")
        XCTAssertEqual(reread.llmPort, 9999)
    }

    func testDirectoriesAreCreated() {
        let dirs = [store.appSupportDir, store.modelsDir, store.meetingsDir, store.recordingsDir]
        for dir in dirs {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), dir.path)
            XCTAssertTrue(isDirectory.boolValue, dir.path)
        }
    }
}
