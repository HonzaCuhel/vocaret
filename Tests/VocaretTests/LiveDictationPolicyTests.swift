import XCTest
@testable import VocaretCore

final class LiveDictationPolicyTests: XCTestCase {
    func testCloudFailureFallsBackWhenLocalSamplesContainSpeech() {
        XCTAssertEqual(
            LiveDictationPolicy.nextStep(
                engine: "soniox",
                cloudResult: .failure,
                hasLocalSpeech: true
            ),
            .transcribeLocally
        )
    }

    func testCloudFailureSkipsLocalModelForSilence() {
        XCTAssertEqual(
            LiveDictationPolicy.nextStep(
                engine: "soniox",
                cloudResult: .failure,
                hasLocalSpeech: false
            ),
            .noTranscript
        )
    }

    func testCloudSuccessUsesCloudTranscript() {
        XCTAssertEqual(
            LiveDictationPolicy.nextStep(
                engine: "soniox",
                cloudResult: .success,
                hasLocalSpeech: true
            ),
            .useCloudTranscript
        )
    }

    func testEmptyCloudTranscriptIsACloudFailure() {
        XCTAssertEqual(
            LiveDictationPolicy.cloudResult(engine: "soniox", transcript: "  \n"),
            .failure
        )
    }

    func testLocalEngineDoesNotClassifyCloudTranscript() {
        XCTAssertEqual(
            LiveDictationPolicy.cloudResult(engine: "whisper", transcript: "unused"),
            .notUsed
        )
    }

    func testStaleJobCannotCleanUpNewerDictation() {
        XCTAssertTrue(DictationJobOwnership.isCurrent(2, activeGeneration: 2))
        XCTAssertFalse(DictationJobOwnership.isCurrent(1, activeGeneration: 2))
        XCTAssertFalse(DictationJobOwnership.isCurrent(1, activeGeneration: nil))
    }

    func testLocalEngineAlwaysTranscribesLocallyWhenSpeechExists() {
        XCTAssertEqual(
            LiveDictationPolicy.nextStep(
                engine: "whisper",
                cloudResult: .notUsed,
                hasLocalSpeech: true
            ),
            .transcribeLocally
        )
    }

    @MainActor
    func testPartialTranscriptIsClearedBetweenRecordings() {
        let model = RecorderModel()
        model.beginRecording()
        model.partialText = "First recording"
        model.endInteraction()
        model.beginRecording()

        XCTAssertEqual(model.partialText, "")
    }
}
