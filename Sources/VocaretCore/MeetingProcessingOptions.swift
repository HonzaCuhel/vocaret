import Foundation

/// Freeze provider selection for the whole recording, including final notes.
struct MeetingProcessingOptions: Sendable {
    let speechEngine: String
    let notesEnabled: Bool
    let notesProvider: MeetingNotesProvider

    init(settings: SettingsStore) {
        speechEngine = settings.asrEngine
        notesEnabled = settings.cleanMeetings
        notesProvider = settings.dictationCleanupModel == "gpt-5-nano" ? .gpt5Nano : .local
    }

    var usesCloudSpeech: Bool { speechEngine == "soniox" }
    var shouldWarmLocalNotes: Bool { notesEnabled && notesProvider == .local }
}
