import Foundation
import XCTest
@testable import VocaretCore

final class SonioxDiarizationTests: XCTestCase {
    func testDiarizationIsOptInWithoutChangingDictationDefaults() throws {
        let ordinary = SonioxConfiguration(apiKey: "test", region: .eu, languageHints: [], terms: [])
        let meeting = SonioxConfiguration(apiKey: "test", region: .eu, languageHints: [], terms: [],
                                          enableSpeakerDiarization: true)
        let ordinaryJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: ordinary.data()) as? [String: Any])
        let meetingJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: meeting.data()) as? [String: Any])
        XCTAssertEqual(ordinaryJSON["enable_speaker_diarization"] as? Bool, false)
        XCTAssertEqual(meetingJSON["enable_speaker_diarization"] as? Bool, true)
        XCTAssertNil(meetingJSON["enable_endpoint_detection"], "Early endpointing harms speaker accuracy")
    }

    func testDecodesOptionalSpeakerAndMillisecondTiming() throws {
        let response = try decode(#"{"tokens":[{"text":"Ahoj","is_final":true,"speaker":"2","start_ms":600,"end_ms":760},{"text":"!","is_final":true}]}"#)
        XCTAssertEqual(response.tokens[0].speaker, "2")
        XCTAssertEqual(response.tokens[0].startMS, 600)
        XCTAssertEqual(response.tokens[0].endMS, 760)
        XCTAssertNil(response.tokens[1].speaker)
        XCTAssertNil(response.tokens[1].startMS)
        XCTAssertNil(response.tokens[1].endMS)
    }

    func testGroupsWordsBySpeakerAndRetainsReturningSpeakerID() throws {
        var subject = SonioxDiarizationAccumulator()
        subject.consume(try decode(#"{"tokens":[{"text":"Ahoj","is_final":true,"speaker":"1","start_ms":600,"end_ms":760},{"text":" všem.","is_final":true,"speaker":"1","start_ms":760,"end_ms":1300},{"text":"Hallo!","is_final":true,"speaker":"2","start_ms":1400,"end_ms":1800},{"text":"Welcome.","is_final":true,"speaker":"1","start_ms":2100,"end_ms":2400}]}"#))
        XCTAssertEqual(subject.finalizedSegments, [
            .init(speakerID: "1", start: 0.6, end: 1.3, text: "Ahoj všem."),
            .init(speakerID: "2", start: 1.4, end: 1.8, text: "Hallo!"),
            .init(speakerID: "1", start: 2.1, end: 2.4, text: "Welcome."),
        ])
        XCTAssertEqual(subject.visibleSegments, subject.finalizedSegments)
    }

    func testTentativeRevisionReplacesSpeakerAndTextWithoutMutatingFinalPrefix() throws {
        var subject = SonioxDiarizationAccumulator()
        subject.consume(try decode(#"{"tokens":[{"text":"Confirmed.","is_final":true,"speaker":"1","start_ms":0,"end_ms":700},{"text":" Tentative","is_final":false,"speaker":"2","start_ms":800,"end_ms":1300}]}"#))
        let committed = subject.finalizedSegments
        subject.consume(try decode(#"{"tokens":[{"text":" Revised.","is_final":false,"speaker":"3","start_ms":800,"end_ms":1500}]}"#))
        XCTAssertEqual(subject.finalizedSegments, committed)
        XCTAssertEqual(subject.visibleSegments, committed + [
            .init(speakerID: "3", start: 0.8, end: 1.5, text: "Revised.")
        ])
        subject.consume(try decode(#"{"tokens":[{"text":" Revised.","is_final":true,"speaker":"3","start_ms":800,"end_ms":1500},{"text":"<fin>","is_final":true}]}"#))
        XCTAssertEqual(subject.visibleSegments, subject.finalizedSegments)
        XCTAssertEqual(subject.finalizedSegments.count, 2)
    }

    func testUnknownSpeakersRemainUnknownAndUntimedTextIsRetained() throws {
        var subject = SonioxDiarizationAccumulator()
        subject.consume(try decode(#"{"tokens":[{"text":"Known.","is_final":true,"speaker":"1","start_ms":100,"end_ms":800},{"text":"Unknown.","is_final":true},{"text":" More.","is_final":true,"speaker":" "},{"text":"<end>","is_final":true}]}"#))
        XCTAssertEqual(subject.finalizedSegments, [
            .init(speakerID: "1", start: 0.1, end: 0.8, text: "Known."),
            .init(speakerID: nil, start: 0.8, end: 0.8, text: "Unknown. More."),
        ])
    }

    func testLongPauseCreatesSeparateTurnsAndInvalidTimesCannotReverseThem() throws {
        var subject = SonioxDiarizationAccumulator()
        subject.consume(try decode(#"{"tokens":[{"text":"First.","is_final":true,"speaker":"1","start_ms":-30,"end_ms":500},{"text":" Later.","is_final":true,"speaker":"1","start_ms":10000,"end_ms":9000}]}"#))
        XCTAssertEqual(subject.finalizedSegments, [
            .init(speakerID: "1", start: 0, end: 0.5, text: "First."),
            .init(speakerID: "1", start: 10, end: 10, text: "Later."),
        ])
    }

    func testEmptyRevisionDropsOnlyTentativeSuffix() throws {
        var subject = SonioxDiarizationAccumulator()
        subject.consume(try decode(#"{"tokens":[{"text":"Final.","is_final":true,"speaker":"1"},{"text":" Maybe.","is_final":false,"speaker":"2"}]}"#))
        subject.consume(try decode(#"{"tokens":[]}"#))
        XCTAssertEqual(subject.visibleSegments, subject.finalizedSegments)
        XCTAssertEqual(subject.finalizedSegments.map(\.text), ["Final."])
    }

    private func decode(_ json: String) throws -> SonioxResponse {
        try JSONDecoder().decode(SonioxResponse.self, from: Data(json.utf8))
    }
}

final class SonioxDiarizationStreamingTests: XCTestCase {
    func testSpeakerOnlyRevisionPublishesAndFinishRetainsFinalMetadata() async throws {
        let first = frame(#"[{"text":"Hello.","is_final":false,"speaker":"1","start_ms":0,"end_ms":500}]"#)
        let revised = frame(#"[{"text":"Hello.","is_final":false,"speaker":"2","start_ms":0,"end_ms":500}]"#)
        let final = frame(#"[{"text":"Hello.","is_final":true,"speaker":"2","start_ms":0,"end_ms":500},{"text":"<fin>","is_final":true}]"#)
        let transport = DiarizationTestTransport(initial: [first, revised], final: final)
        let snapshots = DiarizationSnapshots()
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)
        try await subject.start(onPartial: { _ in }, onDiarizedSegments: { await snapshots.append($0) })
        let text = try await subject.finish()
        let values = await snapshots.values
        XCTAssertEqual(text, "Hello.")
        XCTAssertEqual(values.map { $0.first?.speakerID }, ["1", "2"])
        let finalSegments = await subject.finalizedDiarizedSegments()
        XCTAssertEqual(finalSegments, [.init(speakerID: "2", start: 0, end: 0.5, text: "Hello.")])
    }

    func testEndpointAndUnrequestedFinDoNotCloseActiveMeetingStream() async throws {
        let boundary = frame(#"[{"text":"First.","is_final":true,"speaker":"1","start_ms":0,"end_ms":500},{"text":"<end>","is_final":true},{"text":"<fin>","is_final":true}]"#)
        let transport = DiarizationTestTransport(initial: [boundary], final: frame(#"[{"text":" Later.","is_final":true,"speaker":"2","start_ms":30000,"end_ms":31000},{"text":"<fin>","is_final":true}]"#))
        let updated = expectation(description: "First speaker was published")
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)
        try await subject.start(onPartial: { _ in }, onDiarizedSegments: { segments in
            if segments.count == 1 { updated.fulfill() }
        })
        await fulfillment(of: [updated], timeout: 1)
        try await subject.append([0.1])
        let text = try await subject.finish()
        XCTAssertEqual(text, "First. Later.")
        let segments = await subject.finalizedDiarizedSegments()
        XCTAssertEqual(segments.map(\.speakerID), ["1", "2"])
        XCTAssertEqual(segments.last?.start, 30)
    }

    func testStartDeadlineClosesBlockedConfigurationSend() async throws {
        let transport = DiarizationTestTransport(blockStart: true)
        let subject = SonioxTranscriber(configuration: configuration, transport: transport,
                                       startTimeout: .milliseconds(40))
        let safety = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { await subject.cancel() }
        }
        defer { safety.cancel() }
        do {
            try await subject.start(onPartial: { _ in })
            XCTFail("Stalled configuration must time out")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .transport("Timed out connecting to Soniox."))
        }
        let closed = await transport.closed
        XCTAssertTrue(closed)
    }

    func testStartDeadlineAlsoClosesBlockedConnection() async throws {
        let transport = DiarizationTestTransport(blockConnect: true)
        let subject = SonioxTranscriber(configuration: configuration, transport: transport,
                                       startTimeout: .milliseconds(40))
        let safety = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { await subject.cancel() }
        }
        defer { safety.cancel() }
        do {
            try await subject.start(onPartial: { _ in })
            XCTFail("Stalled connection must time out")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .transport("Timed out connecting to Soniox."))
        }
        let closed = await transport.closed
        XCTAssertTrue(closed)
    }

    func testCancellingStartUnblocksSendAndCannotResurrectTheSession() async throws {
        let transport = DiarizationTestTransport(blockStart: true)
        let subject = SonioxTranscriber(configuration: configuration, transport: transport)
        let start = Task { try await subject.start(onPartial: { _ in }) }
        await transport.waitUntilStartBlocked()
        start.cancel()
        do {
            try await start.value
            XCTFail("Cancelled start must fail")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .cancelled)
        }
        do {
            try await subject.append([0.1])
            XCTFail("A cancelled session must remain closed")
        } catch {
            XCTAssertEqual(error as? SonioxTranscriberError, .invalidState)
        }
    }

    private var configuration: SonioxConfiguration {
        .init(apiKey: "test", region: .eu, languageHints: [], terms: [], enableSpeakerDiarization: true)
    }

    private func frame(_ tokens: String) -> Data { Data("{\"tokens\":\(tokens)}".utf8) }
}

private actor DiarizationSnapshots {
    private(set) var values: [[SonioxDiarizedSegment]] = []
    func append(_ segments: [SonioxDiarizedSegment]) { values.append(segments) }
}

private actor DiarizationTestTransport: SonioxTransport {
    private var incoming: [Data]
    private let final: Data?
    private let blockStart: Bool
    private let blockConnect: Bool
    private var waitingReceive: CheckedContinuation<Data, Error>?
    private var waitingStart: CheckedContinuation<Void, Error>?
    private var startBlockedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var closed = false

    init(initial: [Data] = [], final: Data? = nil, blockStart: Bool = false, blockConnect: Bool = false) {
        incoming = initial
        self.final = final
        self.blockStart = blockStart
        self.blockConnect = blockConnect
    }

    func connect(to _: URL) async throws {
        if blockConnect { try await waitForStartCancellation() }
    }

    func send(_ frame: SonioxOutboundFrame) async throws {
        guard !closed else { throw CancellationError() }
        guard case .text(let text) = frame else { return }
        if text == #"{"type":"finalize"}"#, let final {
            if let waitingReceive {
                self.waitingReceive = nil
                waitingReceive.resume(returning: final)
            } else {
                incoming.append(final)
            }
        } else if blockStart {
            try await waitForStartCancellation()
        }
    }

    func receive() async throws -> Data {
        if !incoming.isEmpty { return incoming.removeFirst() }
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waitingReceive = $0 }
    }

    func close() async {
        closed = true
        waitingReceive?.resume(throwing: CancellationError())
        waitingReceive = nil
        waitingStart?.resume(throwing: CancellationError())
        waitingStart = nil
    }

    func waitUntilStartBlocked() async {
        if waitingStart != nil { return }
        await withCheckedContinuation { startBlockedWaiters.append($0) }
    }

    private func waitForStartCancellation() async throws {
        try await withCheckedThrowingContinuation { continuation in
            waitingStart = continuation
            let waiters = startBlockedWaiters
            startBlockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}
