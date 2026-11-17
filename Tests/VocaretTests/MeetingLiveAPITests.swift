import XCTest
import WhisperKit
@testable import VocaretCore

final class MeetingLiveAPITests: XCTestCase {
    func testTwoSyntheticVoicesWithSoniox() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOCARET_LIVE_MEETING_API_TEST"] == "1",
              let path = environment["VOCARET_MEETING_SYNTHETIC_WAV"] else {
            throw XCTSkip("Opt-in Soniox test using synthetic audio only.")
        }
        let key = try await AsyncAPIKeyAccess.shared.load(.soniox)
        let apiKey = try XCTUnwrap(key)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.jancuhel.vocaret"))
        let settings = SettingsStore(defaults: defaults)
        let session = SonioxTranscriber(configuration: SonioxConfiguration(
            apiKey: apiKey, region: SonioxRegion(rawValue: settings.sonioxRegion) ?? .eu,
            languageHints: ["en"], terms: [], enableSpeakerDiarization: true
        ), finalizationTimeout: .seconds(20))
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        XCTAssertGreaterThan(samples.count, 16_000)
        XCTAssertLessThan(samples.count, 16_000 * 40, "This live test has a bounded synthetic audio budget")
        try await session.start { _ in }
        do {
            for offset in stride(from: 0, to: samples.count, by: 3_200) {
                try await session.append(Array(samples[offset..<min(offset + 3_200, samples.count)]))
            }
            _ = try await session.finish()
            let segments = await session.finalizedDiarizedSegments()
            let speakers = Set(segments.compactMap(\.speakerID))
            XCTAssertGreaterThanOrEqual(speakers.count, 2)
            XCTAssertTrue(segments.contains { $0.text.localizedCaseInsensitiveContains("budget") })
            XCTAssertTrue(segments.contains { $0.text.localizedCaseInsensitiveContains("Friday") })
            XCTAssertTrue(segments.allSatisfy { $0.end >= $0.start })
            print("[meeting-live-api] \(Double(samples.count) / 16_000)s synthetic audio; \(speakers.count) speakers; \(segments.count) turns")
        } catch {
            await session.cancel()
            throw error
        }
    }

    func testGPT5NanoSummarizesSyntheticSpeakerTranscript() async throws {
        guard ProcessInfo.processInfo.environment["VOCARET_LIVE_MEETING_API_TEST"] == "1" else {
            throw XCTSkip("Opt-in GPT-5 nano test using synthetic text only.")
        }
        let key = try await AsyncAPIKeyAccess.shared.load(.openAI)
        let apiKey = try XCTUnwrap(key)
        let result = await MeetingNotesGenerator.shared.generate(markdownTranscript: """
        **Call · Speaker 1 [00:00:00]:** The proposed budget is 100 dollars.

        **Call · Speaker 2 [00:00:04]:** That is too much. I propose 30 dollars instead.

        **Call · Speaker 1 [00:00:08]:** Agreed. The final approved budget is 30 dollars. I will send the report on Friday.
        """, provider: .gpt5Nano, apiKey: apiKey)
        XCTAssertTrue(result.isComplete, result.failure?.localizedDescription ?? "Missing notes")
        let text = try XCTUnwrap(result.markdown)
        XCTAssertTrue(text.contains("30"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Friday"))
        XCTAssertTrue(text.contains("Speaker 1"))
        print("[meeting-live-api] GPT-5 nano completed synthetic speaker-attributed notes")
    }
}
