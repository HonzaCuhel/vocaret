import XCTest
@testable import VocaretCore

final class OpenAIDictationCleanerTests: XCTestCase {
    func testFastFormattingUsesOneRequestForWholeBilingualDictation() async throws {
        let raw = String(repeating: "Zaprvé zkontroluj import. Then check the export. ", count: 15)
        let transport = FastCleanupTransport(output: raw)
        let result = await OpenAIDictationCleaner(transport: transport).processFastDictation(raw, apiKey: "test", vocabulary: [])
        XCTAssertEqual(result.text, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(result.isFormatted)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["input"] as? String, raw)
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertNil((json["text"] as? [String: Any])?["format"])
    }

    func testFastFormattingRejectsChangedAmountWithoutAnotherModelCall() async {
        let transport = FastCleanupTransport(output: "Pošli 300 eur Janě.")
        let result = await OpenAIDictationCleaner(transport: transport).processFastDictation(
            "Pošli 30 eur Janě.", apiKey: "test", vocabulary: []
        )
        XCTAssertEqual(result.text, "Pošli 30 eur Janě.")
        XCTAssertEqual(result.failure, .rejected)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testUsesGPT5NanoResponsesAPIWithLowReasoningAndNoStorage() async throws {
        let response = """
        {
          "status": "completed",
          "output": [{
            "type": "message",
            "content": [{"type": "output_text", "text": "Ahoj, Vocaret."}]
          }]
        }
        """
        let transport = FakeOpenAIResponsesTransport(
            data: Data(response.utf8),
            statusCode: 200
        )
        let cleaner = OpenAIDictationCleaner(transport: transport)

        let cleaned = await cleaner.cleanDictation(
            "ehm ahoj Vocaret",
            apiKey: "sk-test",
            vocabulary: ["Vocaret"]
        )

        XCTAssertEqual(cleaned, "Ahoj, Vocaret.")
        let capturedRequest = await transport.capturedRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.timeoutInterval, 12)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-5-nano")
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual((json["text"] as? [String: Any])?["verbosity"] as? String, "low")
        XCTAssertTrue((json["instructions"] as? String)?.contains("Vocaret") == true)
    }

    func testCorrectedBudgetIsAcceptedInsteadOfFallingBackToBothAmounts() async {
        let corrected = "Maximální budget je 30 dolarů."
        let data = try! JSONSerialization.data(withJSONObject: [
            "status": "completed", "output": [["content": [["type": "output_text", "text": corrected]]]]
        ])
        let cleaner = OpenAIDictationCleaner(transport: FakeOpenAIResponsesTransport(data: data, statusCode: 200))
        let result = await cleaner.cleanDictation(
            "Maximální budget je 100 dolarů, ale teď si uvědomuju, že to je moc, takže ne, vlastně maximální budget je 30 dolarů.",
            apiKey: "test", vocabulary: []
        )
        XCTAssertEqual(result, corrected)
    }

    func testLongDictationGetsTimeToFinishFormatting() throws {
        let text = String(repeating: "Toto je další věta dlouhého diktování. ", count: 100)
        let request = try OpenAIDictationCleaner().makeRequest(text: text, apiKey: "test", vocabulary: [])
        XCTAssertGreaterThan(request.timeoutInterval, 12)
        XCTAssertLessThanOrEqual(request.timeoutInterval, 45)
    }

    func testUnsafeOrFailedResponseFallsBackToRawTranscript() async {
        let unsafeResponse = """
        {
          "status": "completed",
          "output": [{
            "type": "message",
            "content": [{"type": "output_text", "text": "Here is a completely unrelated long answer with invented details."}]
          }]
        }
        """
        let transport = FakeOpenAIResponsesTransport(
            data: Data(unsafeResponse.utf8),
            statusCode: 200
        )
        let cleaner = OpenAIDictationCleaner(transport: transport)
        let raw = "Zitra zavolam Petrovi."

        let cleaned = await cleaner.cleanDictation(raw, apiKey: "sk-test", vocabulary: [])

        XCTAssertEqual(cleaned, raw)
    }

    func testHTTPErrorDoesNotExposeServerBodyAndFallsBack() async {
        let transport = FakeOpenAIResponsesTransport(
            data: Data("sensitive server body".utf8),
            statusCode: 401
        )
        let cleaner = OpenAIDictationCleaner(transport: transport)
        let raw = "Keep this text."

        let result = await cleaner.processDictation(raw, apiKey: "sk-test", vocabulary: [])

        XCTAssertEqual(result.text, raw)
        XCTAssertEqual(result.failure, .unavailable)
        XCTAssertFalse(result.isFormatted)
    }

    func testRejectedAndIncompleteFormattingHaveTruthfulOutcomes() async throws {
        for (status, output, failure) in [
            ("completed", "The budget is 300 dollars.", DictationCleanupFailure.rejected),
            ("incomplete", "The budget is", .incomplete),
            ("completed", "", .incomplete)
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "status": status, "output": [["content": [["type": "output_text", "text": output]]]]
            ])
            let cleaner = OpenAIDictationCleaner(transport: FakeOpenAIResponsesTransport(data: data, statusCode: 200))
            let raw = "The budget is 30 dollars."
            let result = await cleaner.processDictation(raw, apiKey: "test", vocabulary: [])
            XCTAssertEqual(result.text, raw)
            XCTAssertEqual(result.failure, failure)
            XCTAssertFalse(result.isFormatted)
        }
    }
}

private actor FakeOpenAIResponsesTransport: OpenAIResponsesTransport {
    let data: Data
    let statusCode: Int
    private(set) var lastRequest: URLRequest?

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func capturedRequest() -> URLRequest? { lastRequest }
}

private actor FastCleanupTransport: OpenAIResponsesTransport {
    let output: String
    private(set) var requests: [URLRequest] = []
    init(output: String) { self.output = output }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response: [String: Any] = ["status": "completed", "output": [["content": [["type": "output_text", "text": output]]]]]
        return (try JSONSerialization.data(withJSONObject: response),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
