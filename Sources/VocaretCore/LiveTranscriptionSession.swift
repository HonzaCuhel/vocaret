import Foundation

protocol LiveTranscriptionSession: Sendable {
    func start(onPartial: @escaping @Sendable (String) async -> Void) async throws
    func append(_ samples: [Float]) async throws
    func finish() async throws -> String
    func detectedLanguage() async -> String?
    func cancel() async
}

enum SonioxOutboundFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

protocol SonioxTransport: Sendable {
    func connect(to url: URL) async throws
    func send(_ frame: SonioxOutboundFrame) async throws
    func receive() async throws -> Data
    func close() async
}

enum SonioxTransportError: Error, LocalizedError {
    case notConnected
    case unexpectedMessage

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "The Soniox connection is not open."
        case .unexpectedMessage:
            "Soniox returned an unsupported WebSocket message."
        }
    }
}

actor URLSessionSonioxTransport: SonioxTransport {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    func connect(to url: URL) async throws {
        guard task == nil else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
    }

    func send(_ frame: SonioxOutboundFrame) async throws {
        guard let task else { throw SonioxTransportError.notConnected }
        switch frame {
        case .text(let text):
            try await task.send(.string(text))
        case .binary(let data):
            try await task.send(.data(data))
        }
    }

    func receive() async throws -> Data {
        guard let task else { throw SonioxTransportError.notConnected }
        switch try await task.receive() {
        case .string(let text):
            return Data(text.utf8)
        case .data(let data):
            return data
        @unknown default:
            throw SonioxTransportError.unexpectedMessage
        }
    }

    func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}
