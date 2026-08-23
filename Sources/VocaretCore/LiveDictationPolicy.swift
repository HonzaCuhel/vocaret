enum LiveCloudResult: Equatable, Sendable {
    case notUsed
    case success
    case failure
}

enum LiveDictationStep: Equatable, Sendable {
    case useCloudTranscript
    case transcribeLocally
    case noTranscript
}

enum LiveDictationPolicy {
    static func cloudResult(engine: String, transcript: String?) -> LiveCloudResult {
        guard engine == "soniox" else { return .notUsed }
        guard let transcript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure
        }
        return .success
    }

    static func nextStep(
        engine: String,
        cloudResult: LiveCloudResult,
        hasLocalSpeech: Bool
    ) -> LiveDictationStep {
        if engine == "soniox", cloudResult == .success {
            return .useCloudTranscript
        }
        return hasLocalSpeech ? .transcribeLocally : .noTranscript
    }
}

enum DictationJobOwnership {
    static func isCurrent(_ generation: Int, activeGeneration: Int?) -> Bool {
        generation == activeGeneration
    }
}
