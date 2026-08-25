import XCTest
@testable import VocaretCore

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var suiteDefaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "VocaretTests-\(UUID().uuidString)"
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
        XCTAssertEqual(store.asrEngine, "whisper")
        XCTAssertEqual(store.sonioxRegion, "eu")
        XCTAssertFalse(store.cleanDictation)
        XCTAssertEqual(store.dictationCleanupModel, "local")
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
        store.dictationCleanupModel = "gpt-5-nano"
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
        XCTAssertEqual(reread.dictationCleanupModel, "gpt-5-nano")
        XCTAssertFalse(reread.cleanMeetings)
        XCTAssertTrue(reread.keepRecordings)
        XCTAssertEqual(reread.whisperModel, "openai_whisper-small")
        XCTAssertEqual(reread.dictationKeyCode, 11)
        XCTAssertEqual(reread.dictationModifiers, 0x100)
        XCTAssertEqual(reread.llamaServerPath, "/opt/homebrew/bin/llama-server")
        XCTAssertEqual(reread.llmModelPath, "/tmp/model.gguf")
        XCTAssertEqual(reread.llmPort, 9999)
    }

    func testSonioxEngineAndRegionRoundTrip() {
        store.asrEngine = "SONIOX"
        store.sonioxRegion = "us"

        let reread = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reread.asrEngine, "soniox")
        XCTAssertEqual(reread.sonioxRegion, "us")
    }

    func testInvalidEngineAndRegionFallBackToSafeDefaults() {
        store.asrEngine = "unknown"
        store.sonioxRegion = "unknown"

        XCTAssertEqual(store.asrEngine, "whisper")
        XCTAssertEqual(store.sonioxRegion, "eu")
    }

    func testInvalidCleanupModelFallsBackToLocal() {
        store.dictationCleanupModel = "unknown"

        XCTAssertEqual(store.dictationCleanupModel, "local")
    }

    func testSonioxDoesNotRequireLocalModelPreload() {
        XCTAssertEqual(ModelLifecyclePolicy.preloadTarget(engine: "soniox"), .none)
    }

    func testSwitchingFromWhisperToParakeetUnloadsBothBeforePreload() {
        XCTAssertEqual(
            ModelLifecyclePolicy.switchActions(from: "whisper", to: "parakeet"),
            [.unloadWhisper, .unloadParakeet, .preloadParakeet]
        )
    }

    func testSwitchingToSonioxOnlyUnloadsLocalModels() {
        XCTAssertEqual(
            ModelLifecyclePolicy.switchActions(from: "parakeet", to: "soniox"),
            [.unloadWhisper, .unloadParakeet]
        )
    }

    func testStaleEngineSelectionIsIgnored() {
        XCTAssertTrue(ModelLifecyclePolicy.shouldApplySelection(
            requestedEngine: "soniox",
            currentEngine: "soniox"
        ))
        XCTAssertFalse(ModelLifecyclePolicy.shouldApplySelection(
            requestedEngine: "parakeet",
            currentEngine: "soniox"
        ))
    }

    func testCloudFallbackOnlyUnloadsItsOwnGeneration() {
        XCTAssertTrue(ModelLifecyclePolicy.shouldUnloadCloudFallback(
            startingGeneration: 3,
            currentGeneration: 3,
            currentEngine: "soniox"
        ))
        XCTAssertFalse(ModelLifecyclePolicy.shouldUnloadCloudFallback(
            startingGeneration: 3,
            currentGeneration: 4,
            currentEngine: "soniox"
        ))
        XCTAssertFalse(ModelLifecyclePolicy.shouldUnloadCloudFallback(
            startingGeneration: 3,
            currentGeneration: 3,
            currentEngine: "whisper"
        ))
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
