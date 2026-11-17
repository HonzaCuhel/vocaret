import XCTest
@testable import VocaretCore
final class DictationSectionsTests: XCTestCase {
    func testUsesLastFirstBeforeCoherentTaskSequence() {
        let text = "Chci zaprvé všechny extrakce. Kontext. První věc je upravit import. Za druhé zkontroluj data. Za třetí sjednoť JSON."
        let sections = DictationSections.split(text)
        XCTAssertEqual(sections.map(\.ordinal), [nil, 1, 2, 3])
        XCTAssertEqual(sections[0].text, "Chci zaprvé všechny extrakce. Kontext.")
        XCTAssertEqual(sections[1].text, "První věc je upravit import.")
    }
    func testIsolatedOrdinalDoesNotCreateTasks() {
        let text = "This is the first version of the report."
        XCTAssertEqual(DictationSections.split(text), [.init(ordinal: nil, text: text)])
    }
    func testLaterRepairRetainsWholeDocumentContext() {
        let text = "Zaprvé nastav rozpočet 100 korun. Za druhé pošli zprávu Anně. Ještě oprava k prvnímu bodu: rozpočet má být 30 korun."
        XCTAssertEqual(DictationSections.split(text), [.init(ordinal: nil, text: text)])
    }
    func testOpeningConjunctionDoesNotBecomeAnEmptyIntroduction() {
        let sections = DictationSections.split("A zaprvé zkontroluj data. Za druhé nic neposílej.")
        XCTAssertEqual(sections.map(\.ordinal), [1, 2])
    }
}
