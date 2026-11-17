import XCTest
@testable import VocaretCore

final class PlainDictationDocumentTests: XCTestCase {
    func testRemovesFormattingMarkupButPreservesPathsAndVersions() {
        XCTAssertEqual(PlainDictationDocument.plainText("### Kontrola\n\n* Použij **GPT-5.4 Mini** a `KPI_MCPs`."), "Kontrola\n\n• Použij GPT-5.4 Mini a KPI_MCPs.")
    }
    func testRemovesCodeFences() {
        XCTAssertEqual(PlainDictationDocument.plainText("```text\nZkontroluj data.\n```"), "Zkontroluj data.")
    }
}
