import XCTest
@testable import VocaretCore

final class TranscriberStorageTests: XCTestCase {
    func testFirstDownloadKeepsTokenizerWithModels() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = Transcriber.modelConfiguration(model: "test-model", modelsDir: root)
        XCTAssertEqual(config.tokenizerFolder, root, "Never fall back to iCloud-managed Documents")
        XCTAssertEqual(config.downloadBase, root)
        XCTAssertTrue(config.download)
        XCTAssertNil(config.modelFolder)
    }

    func testCachedModelSkipsDownloadAndUsesSameTokenizerCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let modelFolder = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/test-model")
        try FileManager.default.createDirectory(
            at: modelFolder.appendingPathComponent("TextDecoder.mlmodelc"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let config = Transcriber.modelConfiguration(model: "test-model", modelsDir: root)
        XCTAssertFalse(config.download, "Cached weights must not trigger a Hub listing")
        XCTAssertEqual(config.modelFolder, modelFolder.path)
        XCTAssertEqual(config.tokenizerFolder, root)
    }
}
