import XCTest
@testable import VocaretCore

final class DictationSentenceEditsTests: XCTestCase {
    func testListDoesNotAbsorbFollowingConstraint() throws {
        let output = #"{"0000":"Firmy:\n• Apple\n• Nvidia","0001":"Použij Mini."}"#
        XCTAssertEqual(try DictationSentenceEdits.render(output, original: "Firmy jsou Apple a Nvidia. Použij Mini."), "Firmy:\n• Apple\n• Nvidia\n\nPoužij Mini.")
    }
    func testKeepsVersionsAndCorrectionsInOrderedSourceSlots() throws {
        let input = "Použij GPT-5.4 Nano. Teda ne, Mini. Nic neposílej."
        XCTAssertEqual(DictationSentenceEdits.sentences(input).count, 3)
        let output = #"{"0000":"Použij GPT-5.4 Mini.","0001":"","0002":"Nic neposílej."}"#
        XCTAssertEqual(try DictationSentenceEdits.render(output, original: input), "Použij GPT-5.4 Mini. Nic neposílej.")
    }

    func testMissingOrInventedSourceSlotFails() {
        for output in [#"{}"#, #"{"0000":"Uprav data.","0001":"Nic neposílej.","0002":"Přidej graf."}"#] {
            XCTAssertThrowsError(try DictationSentenceEdits.render(output, original: "Uprav data. Nic neposílej."))
        }
    }
}
