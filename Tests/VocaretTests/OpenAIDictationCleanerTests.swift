import XCTest
@testable import VocaretCore

final class OpenAIDictationCleanerTests: XCTestCase {
    func testRepairCannotBypassOriginalIntentReview() async {
        let raw = "Pošli to Petrovi, ne, Janě. Nic nezveřejňuj."
        for edit in [
            #"{"edits":[{"before":"Nic nezveřejňuj.","after":""}]}"#,
            #"{"edits":[{"before":"Petrovi, ne, Janě","after":"Petrovi"}]}"#
        ] {
            let transport = RewriteApprovalTransport(outputs: [edit, "REJECT"])
            let result = await OpenAIDictationCleaner(transport: transport).processDictation(raw, apiKey: "test", vocabulary: [])
            XCTAssertEqual(result.text, raw)
            XCTAssertEqual(result.failure, .rejected)
            let calls = await transport.callCount
            XCTAssertEqual(calls, 2)
        }
    }

    func testNumbersTaskSectionsAfterValidatingTheirText() async {
        let transport = RewriteApprovalTransport(outputs: ["Zkontroluj import.", "Nic neposílej."])
        let result = await OpenAIDictationCleaner(transport: transport).processDictation(
            "Zaprvé zkontroluj import. Za druhé nic neposílej.", apiKey: "test", vocabulary: []
        )
        XCTAssertTrue(result.isFormatted)
        XCTAssertEqual(result.text, "1. Zkontroluj import.\n\n2. Nic neposílej.")
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2)
    }

    func testLongRequestKeepsSourceAndSchemaSlotsInReadingOrder() throws {
        let raw = (0..<100).map { "Sentence \($0) has several words." }.joined(separator: " ")
        let request = try OpenAIDictationCleaner().makeRequest(text: raw, apiKey: "test", vocabulary: [])
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(json["input"] as? String)
        let slots = try JSONDecoder().decode([[String: String]].self, from: Data(input.utf8))
        XCTAssertEqual(slots.map { $0["id"]! }, (0..<DictationSentenceEdits.sentences(raw).count).map(DictationSentenceEdits.key))
        let serialized = String(decoding: body, as: UTF8.self)
        XCTAssertLessThan(try XCTUnwrap(serialized.range(of: "\"0002\"")) .lowerBound,
                          try XCTUnwrap(serialized.range(of: "\"0010\"")) .lowerBound)
    }

    func testStructuredRewriteNeedsIndependentMeaningApproval() async throws {
        let raw = "No takže potřebuju abys prověřil přihlašování. A za druhé chci aby ses podíval na odhlašování."
        let edited = "1. Přihlášení\n\nPrověř přihlašování.\n\n2. Odhlášení\n\nZkontroluj odhlašování."
        XCTAssertFalse(CleanupGuard.isSafe(original: raw, cleaned: edited))
        for verdict in ["ACCEPT", "REJECT", "ACCEPT with reservations"] {
            let transport = RewriteApprovalTransport(outputs: [edited, verdict])
            let result = await OpenAIDictationCleaner(transport: transport).processDictation(raw, apiKey: "test", vocabulary: [])
            XCTAssertEqual(result.isFormatted, verdict == "ACCEPT")
            XCTAssertEqual(result.text, verdict == "ACCEPT" ? edited : raw)
        }
    }

    func testMeaningCheckFailureKeepsOriginal() async {
        let raw = "No takže potřebuju abys prověřil přihlašování. A za druhé chci aby ses podíval na odhlašování."
        let edited = "1. Přihlášení\n\nPrověř přihlašování.\n\n2. Odhlášení\n\nZkontroluj odhlašování."
        let transport = RewriteApprovalTransport(outputs: [edited], failWhenEmpty: true)
        let result = await OpenAIDictationCleaner(transport: transport).processDictation(raw, apiKey: "test", vocabulary: [])
        XCTAssertEqual(result.text, raw)
        XCTAssertEqual(result.failure, .unavailable)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2)
    }

    func testInventedAmountCannotBeApprovedByMeaningCheck() async {
        let raw = "Prověř rozpočet 30 dolarů a termín reportu."
        let edited = "1. Rozpočet\n\nPrověř rozpočet 300 dolarů.\n\n2. Termín\n\nPrověř termín reportu."
        let transport = RewriteApprovalTransport(outputs: [edited, "ACCEPT"])
        let result = await OpenAIDictationCleaner(transport: transport).processDictation(raw, apiKey: "test", vocabulary: [])
        XCTAssertEqual(result.text, raw)
        XCTAssertEqual(result.failure, .rejected)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
    }

    func testLongDictationUsesStructuredResponseAndRendersPlainText() async {
        let raw = String(repeating: "Prosím zkontroluj import. ", count: 45)
        let edits = Dictionary(uniqueKeysWithValues: (0..<DictationSentenceEdits.sentences(raw).count).map { (DictationSentenceEdits.key($0), $0 == 0 ? "Prosím zkontroluj import." : "") })
        let document = String(decoding: try! JSONEncoder().encode(edits), as: UTF8.self)
        let transport = RewriteApprovalTransport(outputs: [document, "ACCEPT"])
        let result = await OpenAIDictationCleaner(transport: transport).processDictation(raw, apiKey: "test", vocabulary: [])
        XCTAssertTrue(result.isFormatted)
        XCTAssertEqual(result.text, "Prosím zkontroluj import.")
        let count = await transport.callCount
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertLessThanOrEqual(count, 2)
    }

    func testUsesGPT54NanoResponsesAPIWithStructuredOutputAndNoStorage() async throws {
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
        XCTAssertEqual(json["model"] as? String, "gpt-5.4-nano")
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual((json["text"] as? [String: Any])?["verbosity"] as? String, "low")
        XCTAssertTrue((json["instructions"] as? String)?.contains("Vocaret") == true)
    }

    func testCorrectedBudgetIsAcceptedInsteadOfFallingBackToBothAmounts() async {
        let corrected = "Maximální budget je 30 dolarů."
        let repair = #"{"edits":[{"before":"Maximální budget je 100 dolarů, ale teď si uvědomuju, že to je moc, takže ne, vlastně maximální budget je 30 dolarů.","after":"Maximální budget je 30 dolarů."}]}"#
        let cleaner = OpenAIDictationCleaner(transport: RewriteApprovalTransport(outputs: [repair, "ACCEPT", corrected]))
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
        XCTAssertEqual(request.timeoutInterval, 45)
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

private actor RewriteApprovalTransport: OpenAIResponsesTransport {
    var outputs: [String]
    var callCount = 0
    let failWhenEmpty: Bool
    init(outputs: [String], failWhenEmpty: Bool = false) {
        self.outputs = outputs
        self.failWhenEmpty = failWhenEmpty
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        callCount += 1
        if outputs.isEmpty && failWhenEmpty { throw URLError(.timedOut) }
        let output = outputs.isEmpty ? "REJECT" : outputs.removeFirst()
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "completed", "output": [["content": [["type": "output_text", "text": output]]]]
        ])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
