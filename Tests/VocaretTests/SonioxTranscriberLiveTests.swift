import XCTest
import WhisperKit
@testable import VocaretCore

final class SonioxTranscriberLiveTests: XCTestCase {
    func testUnrestrictedGermanSyntheticSpeech() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOCARET_LIVE_GERMAN_TEST"] == "1",
              let path = environment["VOCARET_SYNTHETIC_GERMAN_WAV"] else {
            throw XCTSkip("Opt-in synthetic audio test using the configured Soniox account.")
        }
        let key = try await AsyncAPIKeyAccess.shared.load(.soniox)
        let apiKey = try XCTUnwrap(key)
        let appDefaults = try XCTUnwrap(UserDefaults(suiteName: "com.jancuhel.vocaret"))
        let settings = SettingsStore(defaults: appDefaults)
        let session = SonioxTranscriber(configuration: SonioxConfiguration(
            apiKey: apiKey, region: SonioxRegion(rawValue: settings.sonioxRegion) ?? .eu,
            languageHints: [], terms: []
        ))
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        XCTAssertGreaterThan(samples.count, 16_000)
        try await session.start { _ in }
        do {
            for offset in stride(from: 0, to: samples.count, by: 3_200) {
                try await session.append(Array(samples[offset..<min(offset + 3_200, samples.count)]))
            }
            let text = try await session.finish()
            print("[live-german-asr] \(Double(samples.count) / 16_000)s synthetic audio: \(text)")
            for word in ["Hallo", "heiße", "Hans", "geht", "dir"] {
                XCTAssertTrue(text.localizedCaseInsensitiveContains(word), "Missing German word: \(word)")
            }
            XCTAssertFalse(text.localizedCaseInsensitiveContains("my name"))
        } catch {
            await session.cancel()
            throw error
        }
    }
}
