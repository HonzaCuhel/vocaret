import XCTest
@testable import UtterCore

final class LLMPromptsTests: XCTestCase {
    func testDictationPromptInvariants() {
        let prompt = LLMPrompts.dictationSystem
        XCTAssertTrue(prompt.contains("Czech"))
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("Do NOT translate"))
        XCTAssertTrue(prompt.contains("Output ONLY the corrected text"))
        // The model must be warned against executing dictated instructions.
        XCTAssertTrue(prompt.contains("Do NOT answer questions"))
    }

    func testMeetingPromptInvariants() {
        let prompt = LLMPrompts.meetingSystem
        XCTAssertTrue(prompt.contains("Czech"))
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("## Summary"))
        XCTAssertTrue(prompt.contains("## Action items"))
        XCTAssertTrue(prompt.contains("## Cleaned transcript"))
        XCTAssertTrue(prompt.contains("Do NOT invent"))
    }

    func testMeetingUserEmbedsTranscriptVerbatim() {
        let transcript = "**Me [00:00:01]:** Ahoj, tak začneme."
        XCTAssertTrue(LLMPrompts.meetingUser(transcript: transcript).contains(transcript))
    }
}
