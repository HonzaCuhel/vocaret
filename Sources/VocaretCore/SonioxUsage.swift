import Foundation

enum SonioxUsageError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Vocaret could not create the Soniox usage request."
        case .invalidResponse:
            return "Soniox returned usage data that Vocaret could not read."
        case .httpStatus(401):
            return "Soniox could not load usage with this API key and region."
        case .httpStatus(let status):
            return "Soniox usage request failed (HTTP \(status))."
        }
    }
}

protocol SonioxUsageTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionSonioxUsageTransport: SonioxUsageTransport {
    func data(for request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw SonioxUsageError.invalidResponse
        }
        return (data, response.statusCode)
    }
}

struct SonioxUsageSnapshot: Equatable, Sendable {
    let costUSD: Decimal
    let requestCount: Int
    let audioDurationMilliseconds: Int
    let periodStart: Date
    let updatedAt: Date

    var formattedCostUSD: String {
        let value = NSDecimalNumber(decimal: costUSD).doubleValue
        if value > 0, value < 1 {
            return String(format: "$%.4f", value)
        }
        return String(format: "$%.2f", value)
    }

    var formattedAudioDuration: String {
        let totalSeconds = max(0, audioDurationMilliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

struct SonioxUsageClient: Sendable {
    private let transport: any SonioxUsageTransport

    init(transport: any SonioxUsageTransport = URLSessionSonioxUsageTransport()) {
        self.transport = transport
    }

    func fetchCurrentMonth(
        apiKey: String,
        region: SonioxRegion,
        now: Date = Date()
    ) async throws -> SonioxUsageSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let start = calendar.date(from: components) else {
            throw SonioxUsageError.invalidRequest
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard var url = URLComponents(
            url: region.restAPIBaseURL.appendingPathComponent("v1/usage/summary"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SonioxUsageError.invalidRequest
        }
        url.queryItems = [
            URLQueryItem(name: "start_time", value: formatter.string(from: start)),
            URLQueryItem(name: "end_time", value: formatter.string(from: now)),
        ]
        guard let requestURL = url.url else { throw SonioxUsageError.invalidRequest }

        var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, statusCode) = try await transport.data(for: request)
        guard (200..<300).contains(statusCode) else {
            throw SonioxUsageError.httpStatus(statusCode)
        }

        let response: UsageSummaryResponse
        do {
            response = try JSONDecoder().decode(UsageSummaryResponse.self, from: data)
        } catch {
            throw SonioxUsageError.invalidResponse
        }

        let realtime = response.models.first { $0.model == "stt-rt-v5" }
        let costText = realtime?.totalCostUSD ?? "0"
        guard let cost = Decimal(string: costText, locale: Locale(identifier: "en_US_POSIX")) else {
            throw SonioxUsageError.invalidResponse
        }
        return SonioxUsageSnapshot(
            costUSD: cost,
            requestCount: realtime?.totalNumRequests ?? 0,
            audioDurationMilliseconds: realtime?.totalInputAudioDurationMS ?? 0,
            periodStart: start,
            updatedAt: now
        )
    }

    private struct UsageSummaryResponse: Decodable {
        let total: UsageSummaryEntry
        let models: [UsageSummaryEntry]
    }

    private struct UsageSummaryEntry: Decodable {
        let model: String?
        let totalCostUSD: String
        let totalNumRequests: Int
        let totalInputAudioDurationMS: Int

        enum CodingKeys: String, CodingKey {
            case model
            case totalCostUSD = "total_cost_usd"
            case totalNumRequests = "total_num_requests"
            case totalInputAudioDurationMS = "total_input_audio_duration_ms"
        }
    }
}
