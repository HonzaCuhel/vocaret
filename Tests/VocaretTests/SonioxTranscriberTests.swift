import Foundation
import XCTest
@testable import VocaretCore

final class SonioxTranscriberTests: XCTestCase {
    func testFinishSendsSilenceThenFinalizeAndWaitsForFin() async throws {
        let transport = FakeSonioxTransport(afterFinalize: [
            response(tokens: [("Ahoj", true)]),
            response(tokens: [("<fin>", true)]),
        ])
        let subject = SonioxTranscriber(
            configuration: configuration,
            transport: transport,
            finalizationTimeout: .seconds(1)
        )

        try await subject.start(onPartial: { _ in })
        try await subject.append([0.25, -0.25])
        let text = try await subject.finish()

        XCTAssertEqual(text, "Ahoj")
        let frameKinds = await transport.frameKinds()
        let silenceByteCount = await transport.silenceByteCount()
        XCTAssertEqual(frameKinds, [.configuration, .audio, .silence, .finalize])
        XCTAssertEqual(silenceByteCount, 3_200 * MemoryLayout<Float>.size)
    }

    func testReceiveLoopPublishesReplaceablePartialText() async throws {
        let partials = LockedStrings()
        let transport = FakeSonioxTransport(
            initial: [
                response(tokens: [("Aho", false)]),
                response(tokens: [("Ahoj", false)]),
            ],
            afterFinalize: [
                response(tokens: [("Ahoj", true)]),
                response(tokens: [("<fin>", true)]),
            ]
        )
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)

        try await subject.start(onPartial: { partials.append($0) })
        let text = try await subject.finish()
        XCTAssertEqual(text, "Ahoj")
        XCTAssertEqual(partials.values, ["Aho", "Ahoj"])
    }

    func testServerErrorFailsFinalization() async throws {
        let transport = FakeSonioxTransport(afterFinalize: [
            Data(#"{"tokens":[],"error_code":401,"error_type":"unauthenticated","error_message":"Bad key"}"#.utf8)
        ])
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)

        try await subject.start(onPartial: { _ in })
        do {
            _ = try await subject.finish()
            XCTFail("Expected a server error")
        } catch {
            XCTAssertEqual(
                error as? SonioxTranscriberError,
                .server(code: 401, type: "unauthenticated", message: "Bad key", requestID: nil)
            )
        }
    }

    func testFinishedResponseBeforeFinIsPrematureClosure() async throws {
        let transport = FakeSonioxTransport(afterFinalize: [
            response(tokens: [("Done", true)]),
            Data(#"{"tokens":[],"finished":true}"#.utf8),
        ])
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)

        try await subject.start(onPartial: { _ in })
        do {
            _ = try await subject.finish()
            XCTFail("Expected premature closure")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .prematureClosure)
        }
    }

    func testMalformedResponseFailsFinalization() async throws {
        let transport = FakeSonioxTransport(afterFinalize: [Data("not json".utf8)])
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)

        try await subject.start(onPartial: { _ in })
        do {
            _ = try await subject.finish()
            XCTFail("Expected malformed JSON to fail")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .invalidResponse)
        }
    }

    func testFinishTimesOutWithoutFinMarker() async throws {
        let transport = FakeSonioxTransport()
        let sleeper = ControlledSleeper()
        let subject = SonioxTranscriber(
            configuration: configuration,
            transport: transport,
            finalizationTimeout: .seconds(99),
            sleep: { duration in try await sleeper.sleep(for: duration) }
        )

        try await subject.start(onPartial: { _ in })
        let finishTask = Task { try await subject.finish() }
        await transport.waitForFinalize()
        await sleeper.waitUntilSleeping()
        await sleeper.release()
        do {
            _ = try await finishTask.value
            XCTFail("Expected finalization to time out")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .finalizationTimedOut)
        }
        let isClosed = await transport.isClosed()
        XCTAssertTrue(isClosed)
    }

    func testAppendIgnoresEmptyAudioWithoutEndingStream() async throws {
        let transport = FakeSonioxTransport(afterFinalize: [
            response(tokens: [("<fin>", true)])
        ])
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)

        try await subject.start(onPartial: { _ in })
        try await subject.append([])
        _ = try await subject.finish()

        let kinds = await transport.frameKinds()
        XCTAssertEqual(kinds, [.configuration, .silence, .finalize])
    }

    func testCancellingFinishTaskCancelsSession() async throws {
        let transport = FakeSonioxTransport()
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)

        try await subject.start(onPartial: { _ in })
        let finishTask = Task { try await subject.finish() }
        await transport.waitForFinalize()
        finishTask.cancel()

        do {
            _ = try await finishTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .cancelled)
        }
        let isClosed = await transport.isClosed()
        XCTAssertTrue(isClosed)
    }

    func testCancelUnblocksPendingFinish() async throws {
        let transport = FakeSonioxTransport()
        let subject = SonioxTranscriber(
            configuration: configuration,
            transport: transport,
            finalizationTimeout: .seconds(5)
        )

        try await subject.start(onPartial: { _ in })
        let finishTask = Task { try await subject.finish() }
        await transport.waitForFinalize()
        await subject.cancel()

        do {
            _ = try await finishTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .cancelled)
        }
    }

    func testCancellingWhileFinalSilenceSendIsBlockedClosesTransport() async throws {
        let transport = FakeSonioxTransport(blockFinalSilence: true)
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)

        try await subject.start(onPartial: { _ in })
        let finishTask = Task { try await subject.finish() }
        await transport.waitForBlockedFinalSilence()
        finishTask.cancel()

        do {
            _ = try await finishTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .cancelled)
        }
        let isClosed = await transport.isClosed()
        XCTAssertTrue(isClosed)
    }

    func testDetectedLanguageComesFromFinalTokens() async throws {
        let transport = FakeSonioxTransport(afterFinalize: [
            response(tokens: [("Napiš ", true, "cs"), ("to.", true, "cs")]),
            response(tokens: [("<fin>", true, nil)]),
        ])
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)

        try await subject.start(onPartial: { _ in })
        _ = try await subject.finish()

        let language = await subject.detectedLanguage()
        XCTAssertEqual(language, "cs")
    }

    private var configuration: SonioxConfiguration {
        SonioxConfiguration(
            apiKey: "test-key",
            region: .eu,
            languageHints: ["cs", "en"],
            terms: ["Slack"]
        )
    }

    private func response(tokens: [(String, Bool)]) -> Data {
        let object: [String: Any] = [
            "tokens": tokens.map { ["text": $0.0, "is_final": $0.1] }
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func response(tokens: [(String, Bool, String?)]) -> Data {
        let encodedTokens: [[String: Any]] = tokens.map { text, isFinal, language in
            var token: [String: Any] = ["text": text, "is_final": isFinal]
            if let language { token["language"] = language }
            return token
        }
        return try! JSONSerialization.data(withJSONObject: ["tokens": encodedTokens])
    }
}

final class SonioxLiveIntegrationTests: XCTestCase {
    func testConfiguredAccountCanCompleteAStreamingSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOCARET_LIVE_SONIOX_TEST"] == "1" else {
            throw XCTSkip("Set VOCARET_LIVE_SONIOX_TEST=1 to run the paid Soniox smoke test.")
        }
        guard let apiKey = environment["SONIOX_API_KEY"], !apiKey.isEmpty else {
            XCTFail("SONIOX_API_KEY is required for the live Soniox smoke test.")
            return
        }

        let region = environment["SONIOX_REGION"]
            .flatMap(SonioxRegion.init(rawValue:)) ?? .us
        let subject = SonioxTranscriber(
            configuration: SonioxConfiguration(
                apiKey: apiKey,
                region: region,
                languageHints: ["cs", "en"],
                terms: []
            ),
            finalizationTimeout: .seconds(15)
        )

        try await subject.start(onPartial: { _ in })
        try await subject.append(Array(repeating: 0, count: 16_000))
        _ = try await subject.finish()
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor ControlledSleeper {
    private var sleepContinuation: CheckedContinuation<Void, Error>?
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []

    func sleep(for _: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            sleepContinuation = continuation
            let waiters = waitingContinuations
            waitingContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSleeping() async {
        if sleepContinuation != nil { return }
        await withCheckedContinuation { waitingContinuations.append($0) }
    }

    func release() {
        sleepContinuation?.resume()
        sleepContinuation = nil
    }
}

private actor FakeSonioxTransport: SonioxTransport {
    enum FrameKind: Equatable {
        case configuration
        case audio
        case silence
        case finalize
    }

    private struct Frame {
        let kind: FrameKind
        let data: Data
    }

    private var frames: [Frame] = []
    private var incoming: [Data]
    private let afterFinalize: [Data]
    private var receiveContinuation: CheckedContinuation<Data, Error>?
    private var finalizeContinuations: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var didFinalize = false
    private let blockFinalSilence: Bool
    private var blockedSendContinuation: CheckedContinuation<Void, Error>?
    private var blockedSendWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        initial: [Data] = [],
        afterFinalize: [Data] = [],
        blockFinalSilence: Bool = false
    ) {
        incoming = initial
        self.afterFinalize = afterFinalize
        self.blockFinalSilence = blockFinalSilence
    }

    func connect(to _: URL) async throws {}

    func send(_ frame: SonioxOutboundFrame) async throws {
        switch frame {
        case .text(let text) where text == #"{"type":"finalize"}"#:
            frames.append(Frame(kind: .finalize, data: Data(text.utf8)))
            didFinalize = true
            let waiters = finalizeContinuations
            finalizeContinuations.removeAll()
            waiters.forEach { $0.resume() }
            afterFinalize.forEach(enqueue)
        case .text(let text):
            frames.append(Frame(kind: .configuration, data: Data(text.utf8)))
        case .binary(let data):
            let isSilence = !data.isEmpty && data.allSatisfy { $0 == 0 }
            frames.append(Frame(kind: isSilence ? .silence : .audio, data: data))
            if isSilence, blockFinalSilence {
                let waiters = blockedSendWaiters
                blockedSendWaiters.removeAll()
                waiters.forEach { $0.resume() }
                try await withCheckedThrowingContinuation { blockedSendContinuation = $0 }
            }
        }
    }

    func receive() async throws -> Data {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { throw CancellationError() }
        precondition(receiveContinuation == nil, "Only one receive loop is allowed")
        return try await withCheckedThrowingContinuation { receiveContinuation = $0 }
    }

    func close() async {
        closed = true
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
        blockedSendContinuation?.resume(throwing: CancellationError())
        blockedSendContinuation = nil
    }

    func frameKinds() -> [FrameKind] { frames.map(\.kind) }

    func silenceByteCount() -> Int {
        frames.first(where: { $0.kind == .silence })?.data.count ?? 0
    }

    func isClosed() -> Bool { closed }

    func waitForFinalize() async {
        if didFinalize { return }
        await withCheckedContinuation { finalizeContinuations.append($0) }
    }

    func waitForBlockedFinalSilence() async {
        if blockedSendContinuation != nil { return }
        await withCheckedContinuation { blockedSendWaiters.append($0) }
    }

    private func enqueue(_ data: Data) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: data)
        } else {
            incoming.append(data)
        }
    }
}
