import XCTest
@testable import VocaretCore

/// Explicitly opt in: uses the configured OpenAI key and the existing GPT-5 nano
/// model. Only synthetic fixtures are sent; no history, vocabulary or audio.
final class OpenAIDictationCleanerLiveTests: XCTestCase {
    func testMultilingualIntentWithConfiguredModel() async throws {
        guard ProcessInfo.processInfo.environment["VOCARET_LIVE_CLEANUP_TEST"] == "1" else {
            throw XCTSkip("Opt-in live API check; ordinary tests never call a paid model.")
        }
        let key = try await AsyncAPIKeyAccess.shared.load(.openAI)
        let apiKey = try XCTUnwrap(key, "An OpenAI key must already be configured.")
        let fixtures: [(name: String, input: String, keep: [String], remove: [String])] = [
            ("Czech correction", "Ehm maximální budget je 100 dolarů, ale teď si uvědomuju, že to je moc, takže ne, vlastně maximální budget je 30 dolarů.", ["budget", "30", "dolarů"], ["100", "ehm", "vlastně"]),
            ("English back-reference", "The budget is 100 dollars. Send the report Friday. Actually, make the budget 30 dollars.", ["30", "dollars", "report", "Friday"], ["100", "actually"]),
            ("German introduction", "Ähm hallo ich ich heiße Hans wie geht es dir?", ["hallo", "heiße", "Hans", "wie geht es dir"], ["ähm", "ich ich", "my name", "how are"]),
            ("German correction", "Also das Budget beträgt 100 Euro, nein, ich meine 30 Euro.", ["Budget", "30", "Euro"], ["100", "ich meine", "dollars"]),
            ("French correction", "Euh le budget est de 100 euros, non pardon, 30 euros.", ["budget", "30", "euros"], ["100", "euh", "pardon"]),
            ("Spanish correction", "Eh el presupuesto es de 100 euros, perdón, mejor 30 euros.", ["presupuesto", "30", "euros"], ["100", "perdón"]),
            ("Spelled-out amount", "Budget je sto dolarů, vlastně třicet dolarů.", ["budget", "dolarů"], ["sto", "vlastně"]),
            ("Czech recipient correction", "Pošli to Petrovi, ne, Janě. A termín nech na pondělí.", ["Janě", "pondělí"], ["Petrovi"]),
            ("German date correction", "Das Meeting ist am Montag, nein, am Dienstag. Bitte lade Anna ein.", ["Dienstag", "Anna"], ["Montag"]),
            ("Code switching", "Ahoj, prosím zkontroluj tuto německou větu: Hallo, ich heiße Hans. Wie geht es dir? Thanks for your help.", ["Ahoj", "zkontroluj", "heiße Hans", "Wie geht es dir", "Thanks for your help"], ["my name"]),
            ("Independent amounts", "Projekt A má rozpočet 100 dolarů a projekt B 30 dolarů. Rozdíl je 70 dolarů.", ["projekt A", "100", "projekt B", "30", "rozdíl", "70"], []),
            ("Negation and question", "Um do not send the report unless Anna approves. Can you explain why the budget is 30 dollars?", ["do not send", "unless Anna approves", "can you explain why", "30"], ["um", "because"]),
            ("Long Czech correction", "Ehm připravujeme interní prezentaci nového projektu a chci zachovat všechny následující požadavky. Maximální rozpočet je 100 dolarů. První část má vysvětlit, pro koho je aplikace určená a jaký konkrétní problém řeší. Ve druhé části ukaž přihlášení, vytvoření projektu a pozvání kolegy. U každého kroku ponech krátký popisek. Obrázky vyber z existující knihovny, nové zatím neobjednávej. Barevnost má zůstat stejná jako na webu a text musí být dobře čitelný i na menším displeji. Dále potřebuji, potřebuji samostatnou ukázku nastavení jazyka a historie posledních úprav. Pro každý snímek napiš stručné poznámky pro přednášejícího. Celou prezentaci pošli v pátek k připomínkám Anně a Pavlovi. Finální verzi ale nezveřejňuj, dokud ji oba neschválí. Ještě se vrátím k tomu rozpočtu, 100 dolarů je moc, změň ho na 30 dolarů. Termín páteční kontroly zůstává stejný. Na poslední snímek přidej kontaktní adresu a poděkování. Zachovej také možnost exportovat prezentaci do PDF a doplň textové alternativy ke všem důležitým obrázkům.", ["30", "Anně", "Pavlovi", "neschválí", "pátek", "PDF", "textové alternativy", "pozvání kolegy", "poznámky"], ["100", "ehm", "potřebuji, potřebuji"])
        ]
        for fixture in fixtures {
            if let selected = ProcessInfo.processInfo.environment["VOCARET_LIVE_CLEANUP_CASES"],
               !selected.components(separatedBy: ",").contains(fixture.name) { continue }
            let start = Date()
            let result = await OpenAIDictationCleaner(transport: SyntheticFixtureAuditTransport()).processDictation(
                fixture.input, apiKey: apiKey, vocabulary: []
            )
            // Test text is synthetic and safe to include in the verification log.
            print("[live-cleanup] \(fixture.name) \(String(format: "%.2f", Date().timeIntervalSince(start)))s formatted=\(result.isFormatted): \(result.text)")
            XCTAssertTrue(result.isFormatted, "\(fixture.name): formatting failed: \(String(describing: result.failure))")
            if fixture.name == "Spelled-out amount" {
                XCTAssertTrue(result.text.contains("30") || result.text.contains("třicet"))
            }
            for token in fixture.keep {
                XCTAssertTrue(result.text.localizedCaseInsensitiveContains(token), "\(fixture.name): missing \(token)")
            }
            for token in fixture.remove {
                XCTAssertFalse(result.text.localizedCaseInsensitiveContains(token), "\(fixture.name): retained \(token)")
            }
        }
    }
}

private struct SyntheticFixtureAuditTransport: OpenAIResponsesTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try await URLSessionOpenAIResponsesTransport().data(for: request)
        if let text = try? OpenAIDictationCleaner.outputText(from: response.0) {
            print("[synthetic-model-output] \(text)")
        }
        return response
    }
}
