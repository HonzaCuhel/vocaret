import XCTest
import WhisperKit
@testable import VocaretCore

final class TranscriberLanguagePolicyTests: XCTestCase {
    func testRestrictedDetectionConsidersThirdLanguage() async throws {
        var attempted: [String] = []
        let selected = try await Transcriber.decodeAllowedLanguages(["cs", "en", "de"]) { language in
            attempted.append(language)
            return try [Self.result(language: language, score: language == "de" ? -0.1 : -1.5)]
        }
        XCTAssertEqual(attempted, ["cs", "en", "de"])
        XCTAssertEqual(selected?.language, "de")
    }

    func testEmptyCandidateCannotBeatRecognizedSpeech() async throws {
        let selected = try await Transcriber.decodeAllowedLanguages(["cs", "en"]) { language in
            language == "cs" ? [] : try [Self.result(language: language, score: -0.5)]
        }
        XCTAssertEqual(selected?.language, "en")
    }

    func testCancelledRestrictionDoesNotStartAnotherDecode() async throws {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await Transcriber.decodeAllowedLanguages(["cs", "en"]) { _ in
                XCTFail("Cancelled detection must not start inference")
                return []
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }

    private static func result(language: String, score: Float) throws -> TranscriptionResult {
        let segments: [[String: Any]] = [["id": 0, "seek": 0, "start": 0, "end": 1,
            "text": "Recognized speech", "tokens": [], "tokenLogProbs": [], "temperature": 0,
            "avgLogprob": score, "compressionRatio": 1, "noSpeechProb": 0]]
        let object: [String: Any] = [
            "text": "Recognized speech", "language": language,
            "segments": segments,
            "timings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(TranscriptionTimings()))
        ]
        return try JSONDecoder().decode(TranscriptionResult.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testAutomaticLanguageSelectionLeavesDetectionEnabled() {
        let options = Transcriber.decodeOptions(language: "auto")

        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage, "Each automatic decode must detect the language of its own audio")
    }

    func testExplicitGermanSelectionForcesGerman() {
        let options = Transcriber.decodeOptions(language: "de")

        XCTAssertEqual(options.language, "de")
        XCTAssertFalse(options.detectLanguage)
    }

    func testReturningToAutomaticAfterCzechDoesNotReuseCzech() {
        let czech = Transcriber.decodeOptions(language: "cs")
        XCTAssertEqual(czech.language, "cs")

        let automatic = Transcriber.decodeOptions(language: "auto")
        XCTAssertNil(automatic.language)
        XCTAssertTrue(automatic.detectLanguage)
    }
}
