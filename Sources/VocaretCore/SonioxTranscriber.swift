import Foundation

enum SonioxTranscriberError: Error, Equatable, LocalizedError, Sendable {
    case invalidState
    case invalidResponse
    case server(code: Int, type: String, message: String, requestID: String?)
    case transport(String)
    case finalizationTimedOut
    case prematureClosure
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "The live transcription session is not running."
        case .invalidResponse:
            return "Soniox returned a response that Vocaret could not read."
        case .server(let code, let type, let message, _):
            return "Soniox error \(code) \(type): \(message)"
        case .transport(let message):
            return "Soniox connection failed: \(message)"
        case .finalizationTimedOut:
            return "Soniox did not finish the transcript in time."
        case .prematureClosure:
            return "Soniox ended the stream before manual finalization completed."
        case .cancelled:
            return "Live transcription was cancelled."
        }
    }
}

typealias SonioxSleep = @Sendable (Duration) async throws -> Void

private actor OrderedSonioxWriter {
    private let transport: any SonioxTransport
    private var tail: Task<Void, Error>?

    init(transport: any SonioxTransport) {
        self.transport = transport
    }

    func send(_ frame: SonioxOutboundFrame) async throws {
        let previous = tail
        let next = Task { [transport] in
            if let previous { try await previous.value }
            try Task.checkCancellation()
            try await transport.send(frame)
        }
        tail = next
        try await next.value
    }

    func cancel() {
        tail?.cancel()
        tail = nil
    }
}

actor SonioxTranscriber: LiveTranscriptionSession {
    private enum State {
        case idle
        case running
        case finishing
        case terminal
    }

    private let configuration: SonioxConfiguration
    private let transport: any SonioxTransport
    private let writer: OrderedSonioxWriter
    private let finalizationTimeout: Duration
    private let sleep: SonioxSleep

    private var state: State = .idle
    private var accumulator = SonioxTranscriptAccumulator()
    private var onPartial: (@Sendable (String) async -> Void)?
    private var lastPublishedPartial = ""
    private var receiveTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var terminalResult: Result<String, SonioxTranscriberError>?

    init(
        configuration: SonioxConfiguration,
        transport: any SonioxTransport = URLSessionSonioxTransport(),
        finalizationTimeout: Duration = .seconds(5),
        sleep: @escaping SonioxSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.configuration = configuration
        self.transport = transport
        writer = OrderedSonioxWriter(transport: transport)
        self.finalizationTimeout = finalizationTimeout
        self.sleep = sleep
    }

    func start(onPartial: @escaping @Sendable (String) async -> Void) async throws {
        guard state == .idle else { throw SonioxTranscriberError.invalidState }

        do {
            let configurationData = try configuration.data()
            guard let configurationText = String(data: configurationData, encoding: .utf8) else {
                throw SonioxTranscriberError.invalidResponse
            }
            try await transport.connect(to: configuration.region.webSocketURL)
            try await writer.send(.text(configurationText))
        } catch let error as SonioxTranscriberError {
            await transport.close()
            throw error
        } catch {
            await transport.close()
            throw SonioxTranscriberError.transport(error.localizedDescription)
        }

        self.onPartial = onPartial
        state = .running
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func append(_ samples: [Float]) async throws {
        guard state == .running else { throw SonioxTranscriberError.invalidState }
        guard !samples.isEmpty else { return }

        do {
            try await writer.send(.binary(Self.pcmData(samples)))
        } catch {
            let mapped = SonioxTranscriberError.transport(error.localizedDescription)
            await complete(.failure(mapped))
            throw mapped
        }
    }

    func finish() async throws -> String {
        try await withTaskCancellationHandler {
            try await finishWhileActive()
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func detectedLanguage() -> String? {
        accumulator.detectedLanguage
    }

    private func finishWhileActive() async throws -> String {
        guard state == .running else {
            if let terminalResult { return try terminalResult.get() }
            throw SonioxTranscriberError.invalidState
        }
        state = .finishing

        if Task.isCancelled {
            await complete(.failure(.cancelled))
            throw SonioxTranscriberError.cancelled
        }

        do {
            try await writer.send(.binary(Data(count: 3_200 * MemoryLayout<Float>.size)))
            try await writer.send(.text(#"{"type":"finalize"}"#))
        } catch {
            let mapped: SonioxTranscriberError = Task.isCancelled || error is CancellationError
                ? .cancelled
                : .transport(error.localizedDescription)
            await complete(.failure(mapped))
            throw mapped
        }

        if let terminalResult { return try terminalResult.get() }

        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            timeoutTask = Task { [weak self, finalizationTimeout, sleep] in
                do {
                    try await sleep(finalizationTimeout)
                } catch {
                    return
                }
                await self?.finalizationDidTimeOut()
            }
        }
    }

    func cancel() async {
        guard terminalResult == nil else { return }
        await complete(.failure(.cancelled))
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            let data: Data
            do {
                data = try await transport.receive()
            } catch {
                if terminalResult != nil || Task.isCancelled { return }
                await complete(.failure(.transport(error.localizedDescription)))
                return
            }

            let response: SonioxResponse
            do {
                response = try JSONDecoder().decode(SonioxResponse.self, from: data)
            } catch {
                await complete(.failure(.invalidResponse))
                return
            }

            if let errorCode = response.errorCode {
                await complete(.failure(.server(
                    code: errorCode,
                    type: response.errorType ?? "unknown",
                    message: response.errorMessage ?? "Unknown server error.",
                    requestID: response.requestID
                )))
                return
            }

            let update = accumulator.consume(response)
            if !update.visibleText.isEmpty,
               update.visibleText != lastPublishedPartial,
               !update.didFinalize {
                lastPublishedPartial = update.visibleText
                await onPartial?(update.visibleText)
            }
            if update.didFinalize {
                await complete(.success(update.finalText))
                return
            }
            if response.finished {
                await complete(.failure(.prematureClosure))
                return
            }
        }
    }

    private func finalizationDidTimeOut() async {
        guard state == .finishing, terminalResult == nil else { return }
        await complete(.failure(.finalizationTimedOut))
    }

    private func complete(_ result: Result<String, SonioxTranscriberError>) async {
        guard terminalResult == nil else { return }
        terminalResult = result
        state = .terminal
        timeoutTask?.cancel()
        timeoutTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        onPartial = nil
        await writer.cancel()
        await transport.close()

        if let continuation = finishContinuation {
            finishContinuation = nil
            switch result {
            case .success(let text):
                continuation.resume(returning: text)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private static func pcmData(_ samples: [Float]) -> Data {
        let littleEndianBits = samples.map { $0.bitPattern.littleEndian }
        return littleEndianBits.withUnsafeBytes { Data($0) }
    }
}
