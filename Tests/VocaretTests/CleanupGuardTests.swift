import XCTest
@testable import VocaretCore

final class CleanupGuardTests: XCTestCase {

    func testAcceptsGenuineCorrection() {
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "Ten v Hisper zase nefunguje, zeptej se kodexu na revijev.",
            cleaned: "Ten Whisper zase nefunguje, zeptej se Codexu na review."
        ))
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "no takže ehm zítra máme jako schůzku v devět",
            cleaned: "Zítra máme schůzku v devět."
        ))
    }

    func testRejectsTranslation() {
        // The model translated instead of correcting — the user's Czech is gone.
        XCTAssertFalse(CleanupGuard.isSafe(
            original: "Pushni to na github a napiš to do rýdmi.",
            cleaned: "Push that to GitHub and write it in README."
        ))
        XCTAssertFalse(CleanupGuard.isSafe(
            original: "Ten v Hisper zase nefunguje, zeptej se kodexu na revijev.",
            cleaned: "The Whisper doesn't work again, ask Codex for a review."
        ))
    }

    func testRejectsAnsweringInsteadOfCorrecting() {
        XCTAssertFalse(CleanupGuard.isSafe(
            original: "Jaké je hlavní město Francie?",
            cleaned: "Hlavním městem Francie je Paříž."
        ))
    }

    func testRejectsWildlyLongerOutput() {
        XCTAssertFalse(CleanupGuard.isSafe(
            original: "Zítra jedu do Brna.",
            cleaned: "Zítra jedu do Brna. Chtěl bych dodat, že cesta trvá dvě a půl hodiny a "
                + "vlak jede každou hodinu z hlavního nádraží, takže je to pohodlné."
        ))
    }

    func testRejectsEmptyOrTrivialOutput() {
        XCTAssertFalse(CleanupGuard.isSafe(original: "Zítra máme schůzku.", cleaned: ""))
        XCTAssertFalse(CleanupGuard.isSafe(original: "Zítra máme schůzku v devět hodin.", cleaned: "OK."))
    }

    func testDiacriticsAndCasingDoNotCountAsChanges() {
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "zitra mame schuzku v devet",
            cleaned: "Zítra máme schůzku v devět."
        ))
    }

    func testShortDictationsAreStillChecked() {
        XCTAssertTrue(CleanupGuard.isSafe(original: "ano", cleaned: "Ano."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "ano", cleaned: "Yes, absolutely."))
    }
}
