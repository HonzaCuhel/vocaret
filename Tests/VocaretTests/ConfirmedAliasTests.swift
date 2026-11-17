import XCTest
@testable import VocaretCore

final class ConfirmedAliasTests: XCTestCase {
    func testAliasesUseWholePhrasesWithoutCascading() {
        XCTAssertEqual(TranscriptCorrector.applyConfirmedAliases("Alpha beta. Alphabet.", aliases: ["alpha": "beta", "beta": "gamma"]), "beta gamma. Alphabet.")
        XCTAssertEqual(TranscriptCorrector.applyConfirmedAliases("Alpha Tools MCP", aliases: ["Alpha Tools": "Beta Tools", "Alpha Tools MCP": "Correct MCP"]), "Correct MCP")
    }
}
