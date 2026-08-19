import AppKit
import Charts
import SwiftUI

// MARK: - Window controller

/// The one app window. Vocaret is a menu-bar app, so the window is created on
/// demand and the app hops to a regular (Dock-visible) activation policy while
/// it is open, then back to accessory when it closes.
@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {
    public static let shared = MainWindowController()

    private var window: NSWindow?
    private var languageObserver: NSObjectProtocol?

    /// Swap the root view so every L() string re-resolves in the new language.
    private func rebuildContent() {
        guard let window else { return }
        // A new content controller resizes the window to the view's minimum
        // size; keep the user's frame.
        let frame = window.frame
        window.contentViewController = NSHostingController(rootView: MainView().environmentObject(AppModel.shared))
        window.setFrame(frame, display: true)
    }

    /// Menu-bar apps have no main menu, but AppKit routes ⌘C/⌘V/⌘A/⌘Z and
    /// ⌘W/⌘Q through one — without it the search field and vocabulary editor
    /// cannot paste and ⌘Q does nothing while the window is frontmost. The
    /// menu is invisible in the accessory policy and appears with the window.
    public static func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Open Vocaret…"), action: #selector(AppDelegate.openMainWindowFromMenu), keyEquivalent: "o")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide Vocaret"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit Vocaret"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    public func show(section: MainSection? = nil) {
        if let section { AppModel.shared.selectedSection = section }
        if window == nil {
            let hosting = NSHostingController(rootView: MainView().environmentObject(AppModel.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Vocaret"
            window.setContentSize(NSSize(width: 1040, height: 680))
            window.minSize = NSSize(width: 860, height: 540)
            // One toolbar owned by the window → identical title-bar height on
            // every tab. Without this, SwiftUI only creates a toolbar for tabs
            // that declare toolbar items, so History/Meetings looked taller.
            let toolbar = NSToolbar(identifier: "VocaretMainToolbar")
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.center()
            window.setFrameAutosaveName("VocaretMainWindow")
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            languageObserver = NotificationCenter.default.addObserver(forName: .vocaretUILanguageChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebuildContent() }
            }
        }
        NSApp.setActivationPolicy(.regular)
        AppModel.shared.refreshStatus()
        AppModel.shared.refreshMeetings()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        // Back to a pure menu-bar app: no Dock icon, no ⌘-Tab entry.
        NSApp.setActivationPolicy(.accessory)
    }
}

public enum MainSection: String, CaseIterable, Identifiable {
    case dashboard, history, meetings, coach, settings
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return L("Dashboard")
        case .history: return L("History")
        case .meetings: return L("Meetings")
        case .coach: return L("Coach")
        case .settings: return L("Settings")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "chart.bar.xaxis"
        case .history: return "clock.arrow.circlepath"
        case .meetings: return "person.2.wave.2"
        case .coach: return "graduationcap"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Root

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { StatusFooter() }
        } detail: {
            switch model.selectedSection {
            case .dashboard: DashboardView()
            case .history: HistoryView()
            case .meetings: MeetingsView()
            case .coach: CoachView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}

/// Small health strip under the sidebar: model loaded, permissions, LLM.
struct StatusFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow(ok: model.whisperReady, text: model.whisperReady ? L("Whisper ready") : L("Loading model…"))
            statusRow(ok: model.accessibilityGranted, text: model.accessibilityGranted ? L("Accessibility granted") : L("Accessibility missing"))
            statusRow(ok: model.llmAvailable, text: model.llmAvailable ? L("Local LLM installed") : L("LLM not set up"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(ok: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text)
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                heroCards
                HStack(alignment: .top, spacing: 16) {
                    DailyWordsCard(days: model.stats.dailyWords)
                    PeakHoursCard(wordsByHour: model.stats.wordsByHour, peak: model.stats.peakHour)
                }
                RecentTranscriptsCard(records: Array(model.records.prefix(6)))
            }
            .padding(24)
        }
        .navigationTitle(L("Dashboard"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(model.records.isEmpty
                 ? "Hold \(SettingsStore.shared.dictationHotkeyLabel), speak, release — your first words will show up here."
                 : "\(model.stats.totalWords.formatted()) words dictated in \(model.stats.totalSessions) sessions.")
                .foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return L("Good morning")
        case 12..<18: return L("Good afternoon")
        default: return L("Good evening")
        }
    }

    private var heroCards: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            StatCard(title: L("Words today"), value: model.stats.wordsToday.formatted(), detail: "\(model.stats.wordsThisWeek.formatted()) this week", symbol: "text.word.spacing")
            StatCard(title: L("Speaking pace"), value: model.stats.averageWPM > 0 ? "\(Int(model.stats.averageWPM))" : "—", detail: "words per minute", symbol: "gauge.with.dots.needle.33percent")
            StatCard(title: L("Time saved"), value: Self.duration(model.stats.timeSavedSeconds), detail: "vs typing at \(Int(DashboardStats.typingWPM)) wpm", symbol: "hourglass")
            StatCard(title: L("Streak"), value: "\(model.stats.streakDays)", detail: model.stats.streakDays == 1 ? L("day") : L("days in a row"), symbol: "flame")
        }
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return String(format: "%.1f h", seconds / 3600)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Image(systemName: symbol).foregroundStyle(.tint)
            }
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DailyWordsCard: View {
    let days: [DashboardStats.DayWords]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Last 14 days")).font(.headline)
            if days.allSatisfy({ $0.words == 0 }) {
                Text(L("No dictated words in this period yet.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Words", day.words))
                        .cornerRadius(3)
                        .foregroundStyle(.tint)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day()) } }
                .frame(height: 160)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PeakHoursCard: View {
    let wordsByHour: [Int]
    let peak: Int?

    private struct HourBucket: Identifiable { let id: Int; let words: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Peak dictation hours")).font(.headline)
                Spacer()
                if let peak { Text(String(format: "%02d:00", peak)).font(.caption).foregroundStyle(.secondary) }
            }
            if wordsByHour.allSatisfy({ $0 == 0 }) {
                Text(L("Nothing yet.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                // Nominal (string) x axis: with an Int axis the 00 and 23 bars
                // sit on the domain edges and are drawn half-clipped.
                Chart(wordsByHour.enumerated().map { HourBucket(id: $0.offset, words: $0.element) }) { bucket in
                    BarMark(x: .value("Hour", String(format: "%02d", bucket.id)), y: .value("Words", bucket.words))
                        .cornerRadius(2)
                        .foregroundStyle(bucket.id == peak ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.35)))
                }
                .chartXAxis { AxisMarks(values: ["00", "06", "12", "18", "23"]) { value in AxisValueLabel { if let h = value.as(String.self) { Text(h) } } } }
                .frame(height: 160)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct RecentTranscriptsCard: View {
    @EnvironmentObject var model: AppModel
    let records: [DictationRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Recent transcripts")).font(.headline)
                Spacer()
                Button(L("See all")) { model.selectedSection = .history }.buttonStyle(.link)
            }
            if records.isEmpty {
                Text(L("Your dictations will appear here.")).foregroundStyle(.secondary)
            } else {
                ForEach(records) { record in
                    HStack(alignment: .top, spacing: 12) {
                        Text(record.date, format: .dateTime.hour().minute())
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(record.text).lineLimit(2)
                        Spacer(minLength: 8)
                        Button { model.copy(record.text) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help(L("Copy"))
                    }
                    if record.id != records.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var selection: DictationRecord.ID?
    @State private var confirmClear = false

    private var filtered: [DictationRecord] {
        guard !query.isEmpty else { return model.records }
        return model.records.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(filtered, selection: $selection) { record in
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.text).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(record.date, format: .dateTime.day().month().hour().minute())
                        Text("·")
                        Text("\(record.wordCount) words")
                        if record.recordingSeconds > 0 { Text("·"); Text("\(Int(record.wordsPerMinute)) wpm") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(record.id)
            }
            .listStyle(.inset)
            .frame(minWidth: 340, idealWidth: 420, maxWidth: 520)

            Divider()

            Group {
                if let record = filtered.first(where: { $0.id == selection }) {
                    TranscriptDetail(record: record)
                } else {
                    ContentUnavailableView(L("Select a dictation"), systemImage: "text.quote", description: Text("\(model.records.count) transcripts on this Mac. Nothing here has left it."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text(L("Search transcripts")))
        .navigationTitle(L("History"))
        .toolbar {
            ToolbarItem { Button { model.copy(model.records.first?.text ?? "") } label: { Label(L("Copy last"), systemImage: "doc.on.doc") }.disabled(model.records.isEmpty) }
            ToolbarItem {
                Menu {
                    Button(L("Clear all history…"), role: .destructive) { confirmClear = true }.disabled(model.records.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog(
            Text(L("Delete all transcripts?") + " (\(model.records.count))"),
            isPresented: $confirmClear, titleVisibility: .visible
        ) {
            Button(L("Delete All"), role: .destructive) { model.clearHistory() }
        } message: {
            Text(L("This removes the dictation history files from this Mac. It cannot be undone."))
        }
    }
}

struct TranscriptDetail: View {
    @EnvironmentObject var model: AppModel
    let record: DictationRecord
    @State private var copied = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    metaChip("calendar", record.date.formatted(date: .abbreviated, time: .shortened))
                    metaChip("text.word.spacing", "\(record.wordCount) words")
                }
                if record.recordingSeconds > 0 || record.transcriptionSeconds > 0 {
                    GridRow {
                        if record.recordingSeconds > 0 { metaChip("waveform", String(format: "%.1f s spoken · %d wpm", record.recordingSeconds, Int(record.wordsPerMinute))) } else { Color.clear.frame(height: 0) }
                        if record.transcriptionSeconds > 0 { metaChip("bolt", String(format: "%.1f s to transcribe", record.transcriptionSeconds)) } else { Color.clear.frame(height: 0) }
                    }
                }
            }
            ScrollView {
                Text(record.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button {
                    model.copy(record.text); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: { Label(copied ? L("Copied") : L("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Label(L("Delete"), systemImage: "trash") }
                    .confirmationDialog(Text(L("Delete this transcript?")), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button(L("Delete"), role: .destructive) { model.delete(record) }
                    } message: {
                        Text(L("It is removed from the history files on this Mac. It cannot be undone."))
                    }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metaChip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
    }
}
