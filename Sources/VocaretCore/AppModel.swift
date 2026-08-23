import AppKit
import Combine
import Foundation

/// One meeting transcript file on disk.
public struct MeetingFile: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public var url: URL
    public var date: Date
    public var title: String
    public var preview: String
    public var wordCount: Int
}

/// Observable state for the main window. Everything it shows derives from
/// TranscriptHistory, the meetings folder, SettingsStore and the coach.
@MainActor
public final class AppModel: ObservableObject {
    public static let shared = AppModel()

    @Published public private(set) var records: [DictationRecord] = []
    @Published public private(set) var stats = DashboardStats()
    @Published public private(set) var meetings: [MeetingFile] = []
    @Published public private(set) var coachReport: CoachReport?
    @Published public private(set) var coachRunning = false
    @Published public var accessibilityGranted = false
    @Published public var llmAvailable = false
    @Published public var speechEngineReady = false
    @Published public var selectedSection: MainSection = .dashboard

    private var listenerToken: UUID?
    private var coachURL: URL { SettingsStore.shared.appSupportDir.appendingPathComponent("coach-report.json") }

    private init() {
        records = TranscriptHistory.shared.all
        stats = DashboardStats.compute(records: records)
        listenerToken = TranscriptHistory.shared.addListener { [weak self] all in
            Task { @MainActor in
                self?.records = all.reversed()
                self?.stats = DashboardStats.compute(records: all)
            }
        }
        loadCoachReport()
        refreshMeetings()
        refreshStatus()
    }

    // MARK: - Status

    public func refreshStatus() {
        accessibilityGranted = Permissions.accessibilityGranted(promptIfNeeded: false)
        llmAvailable = LLMCleaner.serverBinaryPresent()
        Task {
            let target = ModelLifecyclePolicy.preloadTarget(engine: SettingsStore.shared.asrEngine)
            speechEngineReady = target != .none && !SettingsStore.shared.keepModelLoaded
                ? true
                : await Transcriber.shared.isReady
        }
    }

    // MARK: - History

    public func delete(_ record: DictationRecord) {
        TranscriptHistory.shared.delete(id: record.id)
    }

    public func clearHistory() {
        TranscriptHistory.shared.clear()
    }

    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Meetings

    public func refreshMeetings() {
        let dir = SettingsStore.shared.meetingsDir
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        meetings = files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> MeetingFile? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? url.lastPathComponent
                let title = firstLine.hasPrefix("# ") ? String(firstLine.dropFirst(2)) : firstLine
                let body = text.split(separator: "\n").dropFirst().joined(separator: " ")
                let preview = String(body.prefix(140)).trimmingCharacters(in: .whitespaces)
                return MeetingFile(url: url, date: date, title: title, preview: preview, wordCount: DictationRecord.wordCount(of: text))
            }
            .sorted { $0.date > $1.date }
    }

    public func meetingText(_ meeting: MeetingFile) -> String {
        (try? String(contentsOf: meeting.url, encoding: .utf8)) ?? ""
    }

    public func reveal(_ meeting: MeetingFile) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
    }

    // MARK: - Coach

    public func runCoach(days: Int = 14) {
        guard !coachRunning else { return }
        coachRunning = true
        let records = self.records
        Task {
            let report = await SpeechCoach.report(records: records, days: days) { system, user in
                await LLMCleaner.shared.generate(system: system, user: user)
            }
            self.coachReport = report
            self.coachRunning = false
            self.saveCoachReport(report)
        }
    }

    private func loadCoachReport() {
        guard let data = try? Data(contentsOf: coachURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        coachReport = try? decoder.decode(CoachReport.self, from: data)
    }

    private func saveCoachReport(_ report: CoachReport) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(report).write(to: coachURL, options: .atomic)
    }
}
