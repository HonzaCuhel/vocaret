import Foundation
import XCTest
@testable import VocaretCore

final class SonioxUsageTests: XCTestCase {
    func testFetchesExactRealtimeSpendForCurrentUTCMonthFromEUProject() async throws {
        let response = """
        {
          "total": {
            "model": null,
            "total_cost_usd": "0.0500000000",
            "total_num_requests": 7,
            "total_input_audio_duration_ms": 125000
          },
          "models": [
            {
              "model": "stt-rt-v5",
              "total_cost_usd": "0.0123456789",
              "total_num_requests": 3,
              "total_input_audio_duration_ms": 65000
            },
            {
              "model": "tts-rt-v2",
              "total_cost_usd": "0.0376543211",
              "total_num_requests": 4,
              "total_input_audio_duration_ms": 0
            }
          ]
        }
        """
        let transport = FakeSonioxUsageTransport(data: Data(response.utf8), statusCode: 200)
        let client = SonioxUsageClient(transport: transport)
        let now = ISO8601DateFormatter().date(from: "2026-08-23T20:12:34Z")!

        let usage = try await client.fetchCurrentMonth(apiKey: "secret-key", region: .eu, now: now)

        XCTAssertEqual(usage.costUSD, Decimal(string: "0.0123456789"))
        XCTAssertEqual(usage.requestCount, 3)
        XCTAssertEqual(usage.audioDurationMilliseconds, 65_000)
        XCTAssertEqual(usage.formattedCostUSD, "$0.0123")
        XCTAssertEqual(usage.formattedAudioDuration, "1m 5s")

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.host, "api.eu.soniox.com")
        XCTAssertEqual(request.url?.path, "/v1/usage/summary")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "start_time" })?.value, "2026-08-01T00:00:00Z")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "end_time" })?.value, "2026-08-23T20:12:34Z")
    }

    func testUsesUSProjectEndpoint() async throws {
        let response = #"{"total":{"model":null,"total_cost_usd":"0","total_num_requests":0,"total_input_audio_duration_ms":0},"models":[]}"#
        let transport = FakeSonioxUsageTransport(data: Data(response.utf8), statusCode: 200)
        let client = SonioxUsageClient(transport: transport)

        _ = try await client.fetchCurrentMonth(apiKey: "key", region: .us, now: Date(timeIntervalSince1970: 1_787_510_400))

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.host, "api.soniox.com")
    }

    func testReportsAuthenticationFailureWithoutLeakingResponseBody() async {
        let transport = FakeSonioxUsageTransport(data: Data("sensitive server body".utf8), statusCode: 401)
        let client = SonioxUsageClient(transport: transport)

        do {
            _ = try await client.fetchCurrentMonth(apiKey: "secret-key", region: .us)
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? SonioxUsageError, .httpStatus(401))
            XCTAssertFalse(error.localizedDescription.contains("sensitive"))
            XCTAssertFalse(error.localizedDescription.contains("secret-key"))
        }
    }
}

private actor FakeSonioxUsageTransport: SonioxUsageTransport {
    private let data: Data
    private let statusCode: Int
    private var request: URLRequest?

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, Int) {
        self.request = request
        return (data, statusCode)
    }

    func lastRequest() -> URLRequest? { request }
}
