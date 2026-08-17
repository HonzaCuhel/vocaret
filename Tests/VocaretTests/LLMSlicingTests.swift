import XCTest
@testable import VocaretCore

final class LLMSlicingTests: XCTestCase {
    private func turn(_ i: Int) -> String {
        "**\(i % 2 == 0 ? "Me" : "Them") [00:\(String(format: "%02d", i)):00]:** " + String(repeating: "slovo ", count: 40)
    }

    func testShortTranscriptIsOneSlice() {
        let transcript = (0..<3).map(turn).joined(separator: "\n\n")
        XCTAssertEqual(LLMCleaner.slices(transcript, maxTokens: 5_000).count, 1)
    }

    func testLongTranscriptIsSlicedAtTurnBoundariesUnderBudget() {
        let turns = (0..<60).map(turn)
        let transcript = turns.joined(separator: "\n\n")
        let slices = LLMCleaner.slices(transcript, maxTokens: 1_000)

        XCTAssertGreaterThan(slices.count, 1)
        for slice in slices {
            XCTAssertLessThanOrEqual(LLMCleaner.estimatedTokens(slice), 1_000 + LLMCleaner.estimatedTokens(turn(0)))
            XCTAssertTrue(slice.hasPrefix("**"), "slice must start at a turn boundary")
        }
        // Nothing lost: joining the slices reproduces the transcript.
        XCTAssertEqual(slices.joined(separator: "\n\n"), transcript)
    }

    func testEstimatedTokensIsConservativeForCzech() {
        // ~2.6 tokens per Czech word; our estimate must not undershoot.
        let czech = "Potřebujeme schválit navýšení rozpočtu na příští kvartál kvůli rostoucím nákladům."
        XCTAssertGreaterThanOrEqual(LLMCleaner.estimatedTokens(czech), 11 * 2)
    }
}
