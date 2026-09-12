import XCTest
import AppKit
@testable import VocaretCore

@MainActor
final class RecorderHUDTests: XCTestCase {
    func testImmediateHideClosesPanelEvenWhileHoveredAndClearsRecording() {
        let hud = HUD.shared
        let previousShowHUD = SettingsStore.shared.showHUD
        SettingsStore.shared.showHUD = true
        defer {
            hud.setPointerInside(false)
            SettingsStore.shared.showHUD = previousShowHUD
        }
        hud.beginRecording(status: "Recording", hint: "Stop", level: { 0.5 })
        hud.updatePartial("Hotový text. Finished text.")
        hud.beginTranscribing(status: "Cleaning", hint: "Cancel")
        hud.setPointerInside(true)
        XCTAssertTrue(hud.isPanelVisible)

        hud.hide(immediately: true)

        XCTAssertFalse(hud.isPanelVisible)
        XCTAssertEqual(hud.model.phase, .hidden)
        XCTAssertEqual(hud.model.partialText, "")
        XCTAssertNil(hud.model.levelProvider)
        XCTAssertNil(hud.model.startedAt)
        hud.beginRecording(status: "Next recording", hint: "Stop", level: { 0 })
        XCTAssertTrue(hud.isPanelVisible)
        XCTAssertEqual(hud.model.phase, .recording)
        hud.hide(immediately: true)
    }

    func testBeginRecordingStartsFreshWithSeparateStatusAndHint() {
        let model = RecorderModel()
        model.partialText = "stale words"

        model.beginRecording(status: "Live · Soniox", hint: "Release ⌃⌥D to insert")

        XCTAssertEqual(model.phase, .recording)
        XCTAssertEqual(model.statusText, "Live · Soniox")
        XCTAssertEqual(model.hintText, "Release ⌃⌥D to insert")
        XCTAssertEqual(model.partialText, "")
    }

    func testRecordingPresentationHidesEngineModeLabels() {
        let model = RecorderModel()

        model.beginRecording(status: "Live · Soniox", hint: "Release to insert")
        XCTAssertEqual(model.presentedStatusText, "")

        model.beginRecording(status: "Local transcription", hint: "Release to insert")
        XCTAssertEqual(model.presentedStatusText, "")

        model.beginTranscribing(status: "Finalizing…", hint: "Esc cancels")
        XCTAssertEqual(model.presentedStatusText, "Finalizing…")
    }

    func testBeginTranscribingPreservesTheLatestLiveTranscript() {
        let model = RecorderModel()
        model.beginRecording(status: "Live · Soniox", hint: "Release to insert")
        model.partialText = "Průběžně rozpoznaný text"

        model.beginTranscribing(status: "Finalizing…", hint: "Esc cancels")

        XCTAssertEqual(model.phase, .transcribing)
        XCTAssertEqual(model.statusText, "Finalizing…")
        XCTAssertEqual(model.hintText, "Esc cancels")
        XCTAssertEqual(model.partialText, "Průběžně rozpoznaný text")
    }

    func testEndInteractionClearsTranscriptAndPresentationCopy() {
        let model = RecorderModel()
        model.beginRecording(status: "Local transcription", hint: "Esc cancels")
        model.partialText = "temporary"

        model.endInteraction()

        XCTAssertEqual(model.statusText, "")
        XCTAssertEqual(model.hintText, "")
        XCTAssertEqual(model.partialText, "")
    }

    func testPanelGrowsOnlyWhenSubtitleTextExists() {
        XCTAssertEqual(
            RecorderHUDLayout.panelSize(transcript: ""),
            CGSize(width: 560, height: 72)
        )
        XCTAssertEqual(
            RecorderHUDLayout.panelSize(transcript: "Two words"),
            CGSize(width: 560, height: 96)
        )
    }

    func testLongUnpunctuatedTranscriptShowsNewestWordsWithinThreeLines() {
        let ending = "právě teď vidím poslední slova"
        let transcript = String(repeating: "pokračuji v dlouhém diktování bez teček ", count: 120) + ending
        let visible = RecorderTranscriptPresentation.visibleText(transcript)

        XCTAssertTrue(visible.hasSuffix(ending))
        XCTAssertLessThanOrEqual(transcriptLineCount(visible), 3)
        XCTAssertLessThan(visible.count, transcript.count)
    }

    func testSeveralLongSentencesKeepVisibleEnding() {
        let sentence = String(repeating: "Tato dlouhá věta zabere několik řádků ", count: 12) + ". "
        let ending = "The latest English words are visible."
        let visible = RecorderTranscriptPresentation.visibleText(String(repeating: sentence, count: 5) + ending)

        XCTAssertTrue(visible.hasSuffix(ending))
        XCTAssertLessThanOrEqual(transcriptLineCount(visible), 3)
    }

    func testTranscriptTailPreservesCzechAndEnglishGraphemeClusters() {
        let ending = "Příliš žluťoučký kůň 👩🏽‍💻 cafe\u{301} — last words"
        let transcript = String(repeating: "Široká řeč and English words 👨‍👩‍👧‍👦 ", count: 100) + ending
        let visible = RecorderTranscriptPresentation.visibleText(transcript)

        XCTAssertTrue(visible.hasSuffix(ending))
        XCTAssertTrue(transcript.hasSuffix(visible))
        XCTAssertLessThanOrEqual(transcriptLineCount(visible), 3)
    }

    func testPresentationUpdatesTailWithoutDiscardingFullTranscript() {
        let model = RecorderModel()
        let transcript = String(repeating: "Ještě stále mluvím a vidím průběžný přepis ", count: 100)
        model.partialText = transcript + "první konec"
        let previous = model.presentedPartialText
        model.partialText = transcript + "druhý konec"

        XCTAssertTrue(model.presentedPartialText.hasSuffix("druhý konec"))
        XCTAssertNotEqual(model.presentedPartialText, previous)
        XCTAssertEqual(model.partialText, transcript + "druhý konec")
        XCTAssertEqual(transcriptLineCount(previous), transcriptLineCount(model.presentedPartialText))
        XCTAssertLessThanOrEqual(transcriptLineCount(model.presentedPartialText), 3)
    }

    func testShortTranscriptPreservesAllSentencesAndLineBreaks() {
        let transcript = "A. B. C. D. E.\nHello, světe."
        XCTAssertEqual(RecorderTranscriptPresentation.visibleText(transcript), transcript)
        XCTAssertEqual(RecorderTranscriptPresentation.visibleText(" \n\t "), "")
    }

    func testRecordingPresentationShowsFallbackStatusAlongsideTranscript() {
        let model = RecorderModel()
        model.beginRecording(status: "Live · Soniox", hint: "Release to insert")
        model.partialText = "rozpracovaný text"
        model.statusText = "Cloud unavailable · Local fallback"

        XCTAssertEqual(model.presentedStatusText, "Cloud unavailable · Local fallback")
        XCTAssertEqual(model.presentedPartialText, "rozpracovaný text")
    }

    private func transcriptLineCount(_ text: String) -> Int {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 392, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in
            lines += 1
        }
        return lines
    }

    func testShortTranscriptIsCentredButLongerCopyIsLeadingAligned() {
        XCTAssertTrue(RecorderTranscriptPresentation.shouldCenter("Press D"))
        XCTAssertFalse(RecorderTranscriptPresentation.shouldCenter("This sentence needs normal leading alignment"))
    }

    func testPanelHeightStopsGrowingAfterFourLines() {
        XCTAssertEqual(
            RecorderHUDLayout.panelSize(transcript: "One\nTwo"),
            CGSize(width: 560, height: 116)
        )
        XCTAssertEqual(
            RecorderHUDLayout.panelSize(transcript: "One\nTwo\nThree\nFour"),
            CGSize(width: 560, height: 156)
        )
        XCTAssertEqual(
            RecorderHUDLayout.panelSize(transcript: "One\nTwo\nThree\nFour\nFive\nSix"),
            CGSize(width: 560, height: 156)
        )
    }
}
