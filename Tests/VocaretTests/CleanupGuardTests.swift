import XCTest
@testable import VocaretCore

final class CleanupGuardTests: XCTestCase {

    func testAcceptsExplicitBudgetCorrectionDespiteLargeRemoval() {
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "Maximální budget je 100 dolarů, ale teď si uvědomuju, že to je moc, takže ne, vlastně maximální budget je 30 dolarů.",
            cleaned: "Maximální budget je 30 dolarů."
        ))
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "The maximum budget is 100 dollars, but wait, that is too much, actually make the maximum budget 30 dollars.",
            cleaned: "The maximum budget is 30 dollars."
        ))
    }

    func testAcceptsRemovalOfRepeatedWordsAndMultilingualFillers() {
        XCTAssertTrue(CleanupGuard.isSafe(original: "I I I I I need need need the the report.", cleaned: "I need the report."))
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "Ähm also ich heiße ich heiße Hans und äh also wie geht es dir?",
            cleaned: "Ich heiße Hans. Wie geht es dir?"
        ))
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "Euh alors le budget est de 100 euros, non pardon, enfin je veux dire le budget est de 30 euros.",
            cleaned: "Le budget est de 30 euros."
        ))
    }

    func testAcceptsExplicitGermanAndSpanishRepairsDespiteLargeRemoval() {
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "Das maximale Budget beträgt 100 Euro, aber das ist zu viel, nein, ich meine das maximale Budget beträgt 30 Euro.",
            cleaned: "Das maximale Budget beträgt 30 Euro."
        ))
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "El presupuesto máximo es de 100 euros, pero eso es demasiado, no, perdón, el presupuesto máximo es de 30 euros.",
            cleaned: "El presupuesto máximo es de 30 euros."
        ))
    }

    func testAcceptsRepeatedPhrasesWhenTheyExplainTheDeletion() {
        XCTAssertTrue(CleanupGuard.isSafe(
            original: "Please send please send please send please send the report today.",
            cleaned: "Please send the report today."
        ))
    }

    func testRepetitionDoesNotPermitDroppingUnrelatedDetails() {
        XCTAssertFalse(CleanupGuard.isSafe(
            original: "Tomorrow tomorrow tomorrow we meet Peter in Prague and later call Jane about the new project proposal.",
            cleaned: "Tomorrow we meet Peter."
        ))
        XCTAssertFalse(CleanupGuard.isSafe(
            original: "Please send the report today. Please send the invoice tomorrow. Please call Jane about the meeting in Prague.",
            cleaned: "Please send the report today."
        ))
    }

    func testOrdinaryDiscourseWordsAndNegationDoNotPermitHeavyDeletion() {
        let examples: [(String, String)] = [
            ("Actually we meet Peter tomorrow in Prague and later call Jane about the new project proposal.", "We meet Peter tomorrow."),
            ("Vlastně máme zítra schůzku s Petrem v Praze a potom zavoláme Janě ohledně nabídky pro nový projekt.", "Máme zítra schůzku s Petrem."),
            ("Also wir treffen Peter morgen in Prag und danach rufen wir Jana wegen des neuen Projektangebots an.", "Wir treffen Peter morgen."),
            ("I mean to send the report tomorrow and then call Jane about the meeting with Peter in Prague.", "I mean to send the report."),
        ]
        for (original, cleaned) in examples {
            XCTAssertFalse(CleanupGuard.isSafe(original: original, cleaned: cleaned), original)
        }
    }

    func testRejectsInventedOrSignChangedNumbers() {
        XCTAssertFalse(CleanupGuard.isSafe(original: "Maximální budget je 30 dolarů.", cleaned: "Maximální budget je 300 dolarů."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "The balance is 30 dollars.", cleaned: "The balance is -30 dollars."))
    }

    func testAcceptsEquivalentSpelledAmountsInSupportedLanguages() {
        let examples: [(String, String)] = [
            ("Budget je sto dolarů, vlastně třicet dolarů.", "Budget je 30 dolarů."),
            ("The budget is thirty dollars.", "The budget is 30 dollars."),
            ("The budget is thirty-five dollars.", "The budget is 35 dollars."),
            ("Das Budget beträgt dreißig Euro.", "Das Budget beträgt 30 Euro."),
            ("Le budget est de trente euros.", "Le budget est de 30 euros."),
            ("El presupuesto es de treinta euros.", "El presupuesto es de 30 euros."),
            ("Budget je třicet pět dolarů.", "Budget je 35 dolarů."),
            ("Budget je třicet tisíc dolarů.", "Budget je 30 000 dolarů."),
        ]
        for (original, cleaned) in examples {
            XCTAssertTrue(CleanupGuard.isSafe(original: original, cleaned: cleaned), original)
        }
    }

    func testNumericEquivalenceRequiresTheCompleteSpokenNumber() {
        let examples: [(String, String)] = [
            ("The budget is thirty-five dollars.", "The budget is 30 dollars."),
            ("The budget is thirtyfive dollars.", "The budget is 30 dollars."),
            ("The budget is thirty five dollars.", "The budget is 3005 dollars."),
            ("Budget je třicet pět dolarů.", "Budget je 30 dolarů."),
            ("Budget je třicet dolarů.", "Budget je 300 dolarů."),
        ]
        for (original, cleaned) in examples {
            XCTAssertFalse(CleanupGuard.isSafe(original: original, cleaned: cleaned), original)
        }
    }

    func testEquivalentNumberFormattingPreservesSignsAndGrouping() {
        XCTAssertTrue(CleanupGuard.isSafe(original: "Budget je 30000 dolarů.", cleaned: "Budget je 30 000 dolarů."))
        XCTAssertTrue(CleanupGuard.isSafe(original: "Budget je 30\u{202F}000 dolarů.", cleaned: "Budget je 30000 dolarů."))
        XCTAssertTrue(CleanupGuard.isSafe(original: "The balance is minus thirty dollars.", cleaned: "The balance is -30 dollars."))
        XCTAssertTrue(CleanupGuard.isSafe(original: "Zůstatek je mínus třicet dolarů.", cleaned: "Zůstatek je -30 dolarů."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "The balance is minus thirty dollars.", cleaned: "The balance is 30 dollars."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "Zůstatek je mínus třicet dolarů.", cleaned: "Zůstatek je 30 dolarů."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "The balance is thirty dollars.", cleaned: "The balance is -30 dollars."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "The balance is minus 30 dollars.", cleaned: "The balance is 30 dollars."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "Budget je 30 50 dolarů.", cleaned: "Budget je 3050 dolarů."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "Budget je 30 0000 dolarů.", cleaned: "Budget je 30000 dolarů."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "Budget je 30,50 dolarů.", cleaned: "Budget je 3050 dolarů."))
        XCTAssertFalse(CleanupGuard.isSafe(original: "Budget je ٣٠ dolarů.", cleaned: "Budget je ٣٠٠ dolarů."))
    }

    func testRejectsSevereSummaryAndGermanTranslation() {
        XCTAssertFalse(CleanupGuard.isSafe(
            original: "Zítra máme schůzku s Petrem v Praze a potom odpoledne zavoláme Janě ohledně nabídky pro nový projekt.",
            cleaned: "Zítra máme schůzku s Petrem."
        ))
        XCTAssertFalse(CleanupGuard.isSafe(
            original: "Zítra máme schůzku s Petrem v Praze a potom odpoledne zavoláme Janě ohledně nabídky pro nový projekt.",
            cleaned: "Schůzku."
        ))
        XCTAssertFalse(CleanupGuard.isSafe(original: "Hallo, ich heiße Hans. Wie geht es dir?", cleaned: "Hello, my name is Hans. How are you?"))
    }

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
