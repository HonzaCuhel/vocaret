import XCTest
@testable import VocaretCore

final class TranscriberSanitizeTests: XCTestCase {
    func testStripsSpecialTokens() {
        XCTAssertEqual(
            Transcriber.sanitize("<|startoftranscript|><|cs|> Ahoj světe.<|endoftext|>"),
            "Ahoj světe."
        )
        XCTAssertEqual(Transcriber.sanitize("<|0.00|>Hello there.<|4.20|>"), "Hello there.")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(Transcriber.sanitize("  plain text \n"), "plain text")
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(Transcriber.sanitize("Nothing to do here"), "Nothing to do here")
    }
}
