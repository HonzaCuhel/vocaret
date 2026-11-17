import AppKit
import Darwin
import WhisperKit
import XCTest
@testable import VocaretCore

/// Opt-in real local inference plus the actual floating meeting view. All
/// speech is synthesized to a temporary file; no capture or paid API is used.
@MainActor
final class MeetingStressTests: XCTestCase {
    func testTenMinuteMeetingWithLiveInferenceAndUI() async throws {
        guard ProcessInfo.processInfo.environment["VOCARET_MEETING_STRESS_TEST"] == "1" else {
            throw XCTSkip("Opt-in ten-minute synthetic meeting; requires a cached local model")
        }
        let settings = SettingsStore.shared
        let decoder = settings.modelsDir.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/\(settings.whisperModel)/TextDecoder.mlmodelc"
        )
        guard FileManager.default.fileExists(atPath: decoder.path) else {
            throw XCTSkip("The selected model is not cached; this test must not download it")
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", fixture.path,
            "We will meet on Tuesday at ten. Please bring the latest notes and check the import before the call."]
        try say.run()
        await Task.detached { say.waitUntilExit() }.value
        XCTAssertEqual(say.terminationStatus, 0)
        let speech = try AudioProcessor.loadAudioAsFloatArray(fromPath: fixture.path)
        XCTAssertFalse(speech.isEmpty)
        let pattern = speech + [Float](repeating: 0, count: 16_000)

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
        let metrics = StressMetrics()
        Self.report("[meeting-stress] preparing cached local model")
        await Transcriber.shared.beginMeeting(engine: "whisper")
        let session = MeetingTranscriptionSession(
            release: { await Transcriber.shared.endMeeting() },
            decode: { samples, offset in
                try await Transcriber.shared.transcribeMeetingChunk(samples: samples, offset: offset, engine: "whisper")
            }, onUpdate: { result in
                await MainActor.run {
                    app.liveMeetingTurns = result.turns
                    if let turn = app.liveMeetingTurns.last { HUD.shared.updatePartial(turn.text) }
                    metrics.updates += 1
                }
            }
        )
        HUD.shared.beginRecording(status: "Synthetic meeting stress test", hint: "No microphone or cloud audio", level: { 0.2 })
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                let now = ContinuousClock.now
                metrics.maximumHeartbeatGap = max(metrics.maximumHeartbeatGap, previous.duration(to: now))
                metrics.heartbeats += 1
                previous = now
            }
        }
        defer { heartbeat.cancel(); session.cancel() }
        let totalSamples = 600 * 16_000
        var sent = 0
        var nextCheckpoint = 60 * 16_000
        do {
            while sent < totalSamples {
                for start in stride(from: 0, to: pattern.count, by: 4_000) where sent < totalSamples {
                    let count = min(4_000, pattern.count - start, totalSamples - sent)
                    let packet = Array(pattern[start..<start + count])
                    session.append(packet, speaker: .me)
                    session.append(packet, speaker: .them)
                    sent += count
                    // Match live capture: one 250 ms packet every 250 ms.
                    try await Task.sleep(for: .milliseconds(250))
                    if sent >= nextCheckpoint {
                        Self.report("[meeting-stress] audio_seconds=\(sent / 16_000) rss_bytes=\(Self.residentBytes()) updates=\(metrics.updates) turns=\(app.liveMeetingTurns.count)")
                        nextCheckpoint += 60 * 16_000
                    }
                }
            }
        } catch {
            session.cancel()
            _ = await session.finish()
            throw error
        }
        let result = await session.finish()
        XCTAssertTrue(HUD.shared.isPanelVisible)
        XCTAssertFalse(result.needsRecovery)
        XCTAssertGreaterThan(result.mine.count, 1)
        XCTAssertGreaterThan(result.theirs.count, 1)
        XCTAssertGreaterThan(result.mine.last?.end ?? 0, 570)
        XCTAssertGreaterThan(result.theirs.last?.end ?? 0, 570)
        XCTAssertGreaterThan(metrics.updates, 10)
        XCTAssertGreaterThan(metrics.heartbeats, 10)
        Self.report("[meeting-stress] finished updates=\(metrics.updates) heartbeats=\(metrics.heartbeats) maximum_main_actor_gap=\(metrics.maximumHeartbeatGap)")
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static func residentBytes() -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return info.pti_resident_size
    }
}

@MainActor
private final class StressMetrics {
    var updates = 0
    var heartbeats = 0
    var maximumHeartbeatGap = Duration.zero
}
