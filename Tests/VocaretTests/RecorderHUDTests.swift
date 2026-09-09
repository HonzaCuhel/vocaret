import XCTest
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

    func testTranscriptPresentationKeepsTheLastFourSentences() {
        let transcript = "První věta. Druhá věta? Third sentence! Čtvrtá věta. Poslední rozepsaná věta"

        XCTAssertEqual(
            RecorderTranscriptPresentation.visibleText(transcript),
            "Druhá věta? Third sentence! Čtvrtá věta. Poslední rozepsaná věta"
        )
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
