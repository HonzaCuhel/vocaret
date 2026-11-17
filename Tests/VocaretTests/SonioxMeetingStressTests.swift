import AppKit
import Darwin
import XCTest
@testable import VocaretCore

/// Replays incremental Soniox-shaped tokens through the real meeting session,
/// diarization accumulator and UI, without a key, socket or paid request.
@MainActor
final class SonioxMeetingStressTests: XCTestCase {
    func testTenMinuteSonioxReplayWithLiveUI() async throws {
        guard ProcessInfo.processInfo.environment["VOCARET_SONIOX_STRESS_TEST"] == "1" else {
            throw XCTSkip("Opt-in ten-minute Soniox protocol/UI replay; no API calls")
        }
        let settings = SettingsStore.shared
        let companion = CompanionModel.shared
        let app = AppModel.shared
        let savedHUD = settings.showHUD
        let savedMode = companion.mode
        let savedExpanded = companion.expanded
        let savedCapturing = companion.capturing
        defer {
            HUD.shared.hide(immediately: true)
            settings.showHUD = savedHUD
            companion.mode = savedMode
            companion.expanded = savedExpanded
            companion.capturing = savedCapturing
            app.liveMeetingTurns = []
            app.meetingState = .idle
        }
        settings.showHUD = true
        companion.mode = .meeting
        companion.expanded = true
        companion.capturing = true
        app.meetingState = .recording
        let metrics = ReplayMetrics()
        let configuration = SonioxConfiguration(apiKey: "synthetic-only", region: .eu,
            languageHints: [], terms: [], enableSpeakerDiarization: true)
        let session = SonioxMeetingSession(
            microphone: SonioxTranscriber(configuration: configuration, transport: ReplaySonioxTransport()),
            system: SonioxTranscriber(configuration: configuration, transport: ReplaySonioxTransport())
        ) { result in
            await MainActor.run {
                let turns = result.turns
                app.liveMeetingTurns = turns
                if let last = turns.last { HUD.shared.updatePartial(last.text) }
                metrics.updates += 1
            }
        }
        defer { session.cancel() }
        HUD.shared.beginRecording(status: "Synthetic Soniox replay", hint: "No microphone or cloud request", level: { 0.2 })
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                let now = ContinuousClock.now
                metrics.maximumHeartbeatGap = max(metrics.maximumHeartbeatGap, previous.duration(to: now))
                previous = now
            }
        }
        defer { heartbeat.cancel() }
        let packet = [Float](repeating: 0.125, count: 4_000)
        for index in 1...2_400 {
            session.append(packet, speaker: .me)
            session.append(packet, speaker: .them)
            try await Task.sleep(for: .milliseconds(60))
            if index % 240 == 0 {
                var info = proc_taskinfo()
                _ = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
                Self.report("[soniox-replay] audio_seconds=\(index / 4) rss_bytes=\(info.pti_resident_size) updates=\(metrics.updates) turns=\(app.liveMeetingTurns.count)")
            }
        }
        let result = await session.finish()
        XCTAssertFalse(result.needsRecovery)
        XCTAssertGreaterThan(result.mine.count, 10)
        XCTAssertGreaterThan(result.theirs.count, 10)
        XCTAssertGreaterThan(result.mine.last?.end ?? 0, 599)
        XCTAssertGreaterThan(result.theirs.last?.end ?? 0, 599)
        XCTAssertGreaterThan(metrics.updates, 1_000)
        XCTAssertTrue(HUD.shared.isPanelVisible)
        Self.report("[soniox-replay] finished updates=\(metrics.updates) maximum_main_actor_gap=\(metrics.maximumHeartbeatGap)")
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}

@MainActor
private final class ReplayMetrics {
    var updates = 0
    var maximumHeartbeatGap = Duration.zero
}

private actor ReplaySonioxTransport: SonioxTransport {
    private var incoming: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    private var samples = 0
    private var words = 0

    func connect(to _: URL) async throws {}

    func send(_ frame: SonioxOutboundFrame) async throws {
        guard !closed else { throw CancellationError() }
        switch frame {
        case .text(let text):
            if text == #"{"type":"finalize"}"# {
                enqueue(try JSONSerialization.data(withJSONObject: ["tokens": [["text": "<fin>", "is_final": true]]]))
            }
        case .binary(let data):
            // Do not generate another word for the client's final silence pad.
            guard data.contains(where: { $0 != 0 }) else { return }
            let start = samples
            samples += data.count / MemoryLayout<Float>.size
            let vocabulary = ["Prosím", "zkontroluj", "import.", "Then", "check", "the", "export."]
            let token: [String: Any] = [
                "text": " " + vocabulary[words % vocabulary.count], "is_final": true,
                "language": words % vocabulary.count < 3 ? "cs" : "en",
                "speaker": String((start / (16_000 * 12)) % 2 + 1),
                "start_ms": Double(start) / 16, "end_ms": Double(samples) / 16
            ]
            words += 1
            enqueue(try JSONSerialization.data(withJSONObject: ["tokens": [token]]))
        }
    }

    func receive() async throws -> Data {
        if closed { throw CancellationError() }
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func close() async {
        closed = true
        incoming.removeAll()
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }

    private func enqueue(_ data: Data) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: data)
        } else { incoming.append(data) }
    }
}
