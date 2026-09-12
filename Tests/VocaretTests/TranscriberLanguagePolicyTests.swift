import XCTest
@testable import VocaretCore

final class TranscriberLanguagePolicyTests: XCTestCase {
    func testAutomaticLanguageSelectionLeavesDetectionEnabled() {
        let options = Transcriber.decodeOptions(language: "auto")

        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage, "Each automatic decode must detect the language of its own audio")
    }

    func testExplicitGermanSelectionForcesGerman() {
        let options = Transcriber.decodeOptions(language: "de")

        XCTAssertEqual(options.language, "de")
        XCTAssertFalse(options.detectLanguage)
    }

    func testReturningToAutomaticAfterCzechDoesNotReuseCzech() {
        let czech = Transcriber.decodeOptions(language: "cs")
        XCTAssertEqual(czech.language, "cs")

        let automatic = Transcriber.decodeOptions(language: "auto")
        XCTAssertNil(automatic.language)
        XCTAssertTrue(automatic.detectLanguage)
    }
}
