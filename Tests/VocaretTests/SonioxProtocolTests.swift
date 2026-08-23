import Foundation
import XCTest
@testable import VocaretCore

final class SonioxProtocolTests: XCTestCase {
    func testConfigurationUsesRealtimeV5Float16kAndVocabularyTerms() throws {
        let configuration = SonioxConfiguration(
            apiKey: "secret",
            region: .eu,
            languageHints: ["cs", "en"],
            terms: ["Slack", "pull request"]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: configuration.data()) as? [String: Any]
        )
        XCTAssertEqual(object["api_key"] as? String, "secret")
        XCTAssertEqual(object["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(object["audio_format"] as? String, "pcm_f32le")
        XCTAssertEqual(object["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(object["num_channels"] as? Int, 1)
        XCTAssertEqual(object["language_hints"] as? [String], ["cs", "en"])
        XCTAssertEqual(object["enable_language_identification"] as? Bool, true)
        XCTAssertEqual(
            (object["context"] as? [String: Any])?["terms"] as? [String],
            ["Slack", "pull request"]
        )
        XCTAssertEqual(configuration.region.webSocketURL.absoluteString,
                       "wss://stt-rt.eu.soniox.com/transcribe-websocket")
    }

    func testAccumulatorReplacesTentativeSuffixAndStopsAtFin() throws {
        var subject = SonioxTranscriptAccumulator()

        XCTAssertEqual(
            try subject.consume(response(tokens: [("Aho", false)])).visibleText,
            "Aho"
        )
        XCTAssertEqual(
            try subject.consume(response(tokens: [("Ahoj", false)])).visibleText,
            "Ahoj"
        )
        XCTAssertEqual(
            try subject.consume(response(tokens: [("Ahoj ", true)])).visibleText,
            "Ahoj "
        )

        let update = try subject.consume(response(tokens: [("<fin>", true)]))
        XCTAssertEqual(update.visibleText, "Ahoj ")
        XCTAssertEqual(update.finalText, "Ahoj")
        XCTAssertTrue(update.didFinalize)
    }

    func testAccumulatorKeepsFinalPrefixWhileReplacingOnlyNonFinalTokens() throws {
        var subject = SonioxTranscriptAccumulator()

        _ = try subject.consume(response(tokens: [("Hello ", true), ("wor", false)]))
        let revised = try subject.consume(response(tokens: [("world", false)]))
        XCTAssertEqual(revised.visibleText, "Hello world")

        let committed = try subject.consume(
            response(tokens: [("world", true), ("!", true), ("<end>", true)])
        )
        XCTAssertEqual(committed.visibleText, "Hello world!")
        XCTAssertFalse(committed.didFinalize)
    }

    func testAccumulatorAcceptsResponsesWithoutTokens() throws {
        var subject = SonioxTranscriptAccumulator()
        let update = try subject.consume(Data("{}".utf8))
        XCTAssertEqual(
            update,
            SonioxTranscriptUpdate(
                visibleText: "",
                finalText: "",
                detectedLanguage: nil,
                didFinalize: false
            )
        )
    }

    func testAccumulatorReportsDominantFinalTokenLanguage() throws {
        var subject = SonioxTranscriptAccumulator()
        let data = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                ["text": "Ahoj ", "is_final": true, "language": "cs"],
                ["text": "ze ", "is_final": true, "language": "cs"],
                ["text": "Slacku", "is_final": true, "language": "en"],
                ["text": "<fin>", "is_final": true],
            ]
        ])

        let update = try subject.consume(data)

        XCTAssertEqual(update.finalText, "Ahoj ze Slacku")
        XCTAssertEqual(update.detectedLanguage, "cs")
        XCTAssertTrue(update.didFinalize)
    }

    private func response(tokens: [(String, Bool)]) throws -> Data {
        let object: [String: Any] = [
            "tokens": tokens.map { ["text": $0.0, "is_final": $0.1] }
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}
