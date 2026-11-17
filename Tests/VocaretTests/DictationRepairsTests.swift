import XCTest
@testable import VocaretCore

final class DictationRepairsTests: XCTestCase {
    func testSimpleCorrectionProofRequiresExactFinalTokenAndNoOtherEdits() throws {
        XCTAssertTrue(try DictationRepairs.consistsOfSimpleTokenCorrections(#"{"edits":[{"before":"Martinovi, ne, Evě","after":"Evě"}]}"#))
        XCTAssertTrue(try DictationRepairs.consistsOfSimpleTokenCorrections(#"{"edits":[{"before":"Pošli to Martinovi, ne, Evě.","after":"Pošli to Evě."}]}"#))
        XCTAssertFalse(try DictationRepairs.consistsOfSimpleTokenCorrections(#"{"edits":[{"before":"Pošli to Martinovi, ne, Evě. Nic nezveřejňuj.","after":"Pošli to Evě."}]}"#))
        XCTAssertFalse(try DictationRepairs.consistsOfSimpleTokenCorrections(#"{"edits":[{"before":"Martinovi, ne, Evě","after":"Martinovi"}]}"#))
        XCTAssertFalse(try DictationRepairs.consistsOfSimpleTokenCorrections(#"{"edits":[{"before":"Martinovi, ne, Evě","after":"Evě"},{"before":"Nic neposílej.","after":""}]}"#))
    }
    func testAppliesAnchoredCorrectionsAndPreservesUnrelatedRequest() throws {
        let input = "Budget je 80 eur. Pošli report Anně. Vlastně změň budget na 20 eur."
        let edits = #"{"edits":[{"before":"Budget je 80 eur.","after":"Budget je 20 eur."},{"before":"Vlastně změň budget na 20 eur.","after":""}]}"#
        XCTAssertEqual(try DictationRepairs.apply(edits, to: input), "Budget je 20 eur. Pošli report Anně. ")
    }
    func testRejectsAmbiguousQuoteAndInventedAmount() {
        XCTAssertThrowsError(try DictationRepairs.apply(#"{"edits":[{"before":"80","after":"20"}]}"#, to: "80 eur a 80 korun, vlastně 20 korun."))
        XCTAssertThrowsError(try DictationRepairs.apply(#"{"edits":[{"before":"80","after":"900"}]}"#, to: "80 eur, vlastně 20 eur."))
    }
    func testRecognizesCorrectionButNotOrdinaryNegativeInstruction() {
        XCTAssertTrue(DictationRepairs.needsRepair("Pošli to Petrovi, ne, Janě."))
        XCTAssertFalse(DictationRepairs.needsRepair("Do not send the report unless Anna approves."))
    }
}
