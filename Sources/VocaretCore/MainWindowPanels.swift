import AppKit
import SwiftUI

// MARK: - Meetings

struct MeetingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: MeetingFile.ID?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 0) {
            List(model.meetings, selection: $selection) { meeting in
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title).lineLimit(1)
                    Text(meeting.preview).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                    Text("\(meeting.wordCount) words").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
                .tag(meeting.id)
            }
            .listStyle(.inset)
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)

            Divider()

            if let meeting = model.meetings.first(where: { $0.id == selection }) {
                let text = model.meetingText(meeting)
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        MarkdownText(text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button {
                            model.copy(text); copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                        } label: { Label(copied ? L("Copied") : L("Copy transcript"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                        Button { model.reveal(meeting) } label: { Label(L("Show in Finder"), systemImage: "folder") }
                        Button { NSWorkspace.shared.open(meeting.url) } label: { Label(L("Open"), systemImage: "arrow.up.forward.app") }
                        Spacer()
                    }
                }
                .padding(20)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    "No meeting selected",
                    systemImage: "person.2.wave.2",
                    description: Text(model.meetings.isEmpty
                        ? "Press \(SettingsStore.shared.meetingHotkeyLabel) during a call. The transcript lands here — and only here."
                        : "\(model.meetings.count) transcripts in ~/Documents/Vocaret/Meetings")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(L("Meetings"))
        .toolbar {
            ToolbarItem { Button { model.refreshMeetings() } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") } }
            ToolbarItem { Button { NSWorkspace.shared.open(SettingsStore.shared.meetingsDir) } label: { Label(L("Open folder"), systemImage: "folder") } }
        }
        .onAppear { model.refreshMeetings() }
    }
}

/// Renders our own Markdown (headings, bold, bullets) well enough to read
/// meeting notes; falls back to plain text for anything exotic.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("# ") {
                    Text(line.dropFirst(2)).font(.title2.weight(.semibold)).padding(.top, 4)
                } else if line.hasPrefix("## ") {
                    Text(line.dropFirst(3)).font(.headline).padding(.top, 8)
                } else if line.hasPrefix("> ") {
                    Text(inline(String(line.dropFirst(2)))).foregroundStyle(.secondary).italic()
                } else if line.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 6) { Text("•"); Text(inline(String(line.dropFirst(2)))) }
                } else if line == "---" {
                    Divider()
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(inline(line))
                }
            }
        }
        .textSelection(.enabled)
        .font(.system(size: 14))
    }

    private func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
    }
}

// MARK: - Coach

struct CoachView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Speaking coach")).font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text(L("Reads your last two weeks of dictation — on this Mac only — and tells you what to work on."))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.runCoach()
                    } label: {
                        if model.coachRunning { ProgressView().controlSize(.small).padding(.trailing, 4); Text(L("Analyzing…")) }
                        else { Label(model.coachReport == nil ? L("Analyze my speaking") : L("Analyze again"), systemImage: "sparkles") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.coachRunning || model.records.isEmpty)
                }

                if let report = model.coachReport {
                    metrics(report)
                    section(L("What I noticed")) {
                        ForEach(Array(report.observations.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 8) { Text("→").foregroundStyle(.tint); Text(line) }
                        }
                    }
                    if let advice = report.advice {
                        section(L("Your coach says")) {
                            Text(advice).lineSpacing(3).textSelection(.enabled)
                        }
                    } else {
                        section(L("Your coach says")) {
                            Text(model.llmAvailable
                                 ? "The local model was not reachable — the measurements and reading list above still apply. Try again in a moment."
                                 : "Personal advice needs the local LLM. Run `scripts/setup_llm.sh` once (installs llama.cpp and a 2.4 GB model); everything stays on this Mac.")
                            .foregroundStyle(.secondary)
                        }
                    }
                    section(L("Worth reading")) {
                        Text(report.books.contains { $0.pickedBecause != nil }
                             ? "Picked for you from a curated list, based on the measurements above."
                             : "General picks — nothing in the measurements stood out yet. Dictate more and the list adapts.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(report.books) { book in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if let url = URL(string: book.url) {
                                        Link(destination: url) { Text(book.title).fontWeight(.semibold) }
                                        Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.tint)
                                    } else {
                                        Text(book.title).fontWeight(.semibold)
                                    }
                                    Text("— \(book.author)").foregroundStyle(.secondary)
                                }
                                if let because = book.pickedBecause {
                                    Label(because, systemImage: "target").font(.caption).foregroundStyle(.tint)
                                }
                                Text(book.why).font(.callout)
                                if let cz = book.czechEdition {
                                    if let czURL = book.czechURL.flatMap(URL.init(string:)) {
                                        Link(destination: czURL) { Text("česky: \(cz)").font(.caption) }
                                    } else {
                                        Text("česky: \(cz)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    Text("Based on \(report.sampleSize) dictations · \(report.wordsAnalyzed) words · \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                } else if model.records.isEmpty {
                    ContentUnavailableView(L("Nothing to coach yet"), systemImage: "graduationcap", description: Text(L("Dictate for a day or two, then come back.")))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    Text(L("Press *Analyze my speaking*. Measurements are computed locally; the personal note comes from the local LLM if it is set up."))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .navigationTitle(L("Coach"))
    }

    private func metrics(_ report: CoachReport) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            StatCard(title: L("Filler words"), value: String(format: "%.1f%%", report.fillerRate),
                     detail: report.topFillers.prefix(3).joined(separator: ", ").isEmpty ? "of all words" : report.topFillers.prefix(3).joined(separator: ", "), symbol: "ellipsis.bubble")
            StatCard(title: L("Sentence length"), value: String(format: "%.0f", report.averageSentenceLength), detail: "words on average", symbol: "text.alignleft")
            StatCard(title: L("Vocabulary"), value: String(format: "%.0f%%", report.vocabularyRichness * 100), detail: L("distinct words per 100"), symbol: "character.book.closed")
            StatCard(title: L("Pace"), value: report.averageWPM > 0 ? "\(Int(report.averageWPM))" : "—", detail: "words per minute", symbol: "gauge.with.dots.needle.50percent")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var settings = SettingsSnapshot()
    @State private var recordingHotkey: HotkeyTarget?
    @State private var hotkeyProblem: String?
    @State private var vocabularyText = ""
    @State private var sonioxKeyEntry = ""
    @State private var sonioxKeySaved = false
    @State private var sonioxKeyStatus: String?
    @State private var sonioxKeyBusy = false
    @State private var sonioxUsage: SonioxUsageSnapshot?
    @State private var sonioxUsageStatus: String?
    @State private var sonioxUsageBusy = false

    enum HotkeyTarget { case dictation, meeting }

    var body: some View {
        Form {
            Section(L("Shortcuts")) {
                hotkeyRow(L("Dictation"), label: settings.dictationLabel, target: .dictation)
                hotkeyRow(L("Meeting"), label: settings.meetingLabel, target: .meeting)
                if let hotkeyProblem {
                    Text(hotkeyProblem).font(.caption).foregroundStyle(.orange)
                }
                Toggle(L("Hold to talk (release inserts); a quick tap toggles"), isOn: $settings.pushToTalk)
                Text(L("Changes to shortcuts apply after you restart Vocaret.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Transcription")) {
                Picker(L("Speech engine"), selection: $settings.asrEngine) {
                    Text("Whisper").tag("whisper")
                    Text("Parakeet").tag("parakeet")
                    Text(L("Soniox Live")).tag("soniox")
                }
                Text(speechEngineDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("Transcribe"), selection: $settings.language) {
                    Text(L("Auto-detect")).tag("auto"); Text("Čeština").tag("cs"); Text("English").tag("en")
                    // A value set via `defaults write` that is not in the list
                    // would otherwise render as an empty pop-up.
                    if !["auto", "cs", "en"].contains(settings.language) {
                        Text(L("Custom: ") + settings.language).tag(settings.language)
                    }
                }
                if settings.language == "auto" {
                    DisclosureGroup(L("Detection languages")) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 4) {
                            ForEach(L10n.detectableLanguages, id: \.code) { lang in
                                Toggle(lang.name, isOn: Binding(
                                    get: { settings.autoLanguages.contains(lang.code) },
                                    set: { on in
                                        var set = settings.autoLanguages
                                        if on { if !set.contains(lang.code) { set.append(lang.code) } } else { set.removeAll { $0 == lang.code } }
                                        settings.autoLanguages = set
                                    }
                                )).toggleStyle(.checkbox)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                if settings.asrEngine == "soniox" {
                    Picker(L("Processing region"), selection: $settings.sonioxRegion) {
                        Text("European Union — requires an EU project key").tag("eu")
                        Text("United States").tag("us")
                    }
                    if sonioxKeySaved {
                        HStack {
                            Label(L("Connected"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button(L("Disconnect"), role: .destructive) { removeSonioxKey() }
                                .disabled(sonioxKeyBusy)
                        }
                        Divider()
                        LabeledContent(L("Soniox spend this month")) {
                            if let sonioxUsage {
                                Text(sonioxUsage.formattedCostUSD)
                                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            } else if sonioxUsageBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let sonioxUsage {
                                Text("\(sonioxUsage.requestCount) \(L("requests")) · \(sonioxUsage.formattedAudioDuration) \(L("audio"))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let sonioxUsageStatus {
                                Text(sonioxUsageStatus)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                Task { await refreshSonioxUsage() }
                            } label: {
                                Label(L("Refresh usage"), systemImage: "arrow.clockwise")
                            }
                            .labelStyle(.iconOnly)
                            .controlSize(.small)
                            .disabled(sonioxUsageBusy)
                            .help(L("Refresh usage"))
                        }
                        Text(L("Exact stt-rt-v5 project usage from Soniox for the current UTC month."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        SecureField(L("Soniox API key"), text: $sonioxKeyEntry)
                            .disabled(sonioxKeyBusy)
                        HStack {
                            Button(L("Connect")) { saveSonioxKey() }
                                .buttonStyle(.borderedProminent)
                                .disabled(sonioxKeyBusy || sonioxKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if sonioxKeyBusy {
                                ProgressView().controlSize(.small)
                            }
                            if let sonioxKeyStatus {
                                Text(sonioxKeyStatus).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    Text(L("Soniox streams dictation audio to the selected region. The key stays in protected storage on this Mac; local fallback is automatic."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if settings.asrEngine == "whisper" {
                    Picker(L("Speech model"), selection: $settings.whisperModel) {
                        Text("Large v3 turbo — best for Czech (1.6 GB)").tag("openai_whisper-large-v3-v20240930")
                        Text("Large v3 turbo, compressed (626 MB)").tag("openai_whisper-large-v3-v20240930_626MB")
                        Text("Large v3 — slowest, most accurate (3 GB)").tag("openai_whisper-large-v3")
                        if !Self.knownWhisperModels.contains(settings.whisperModel) {
                            Text(L("Custom: ") + settings.whisperModel).tag(settings.whisperModel)
                        }
                    }
                    Text(L("A new model downloads on next launch. Smaller models are much worse at Czech."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Interface")) {
                Picker(L("Interface language"), selection: $settings.uiLanguage) {
                    Text(L("System")).tag("system"); Text("English").tag("en"); Text("Čeština").tag("cs")
                }
                Picker(L("Appearance"), selection: $settings.appearance) {
                    ForEach(Appearance.options, id: \.id) { option in Text(L(option.title)).tag(option.id) }
                }
            }
            Section(L("AI cleanup (local LLM)")) {
                Toggle(L("Clean dictation with AI (adds ~1–2 s)"), isOn: $settings.cleanDictation)
                Toggle(L("Structure meeting notes with AI"), isOn: $settings.cleanMeetings)
                HStack {
                    Circle().fill(model.llmAvailable ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(model.llmAvailable ? L("llama-server installed") : L("Not installed — run scripts/setup_llm.sh in the project folder"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Vocabulary")) {
                Text(L("One term per line. Vocaret always spells these your way, and the AI cleanup is told about them.")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $vocabularyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                HStack {
                    Button(L("Save vocabulary")) {
                        Vocabulary.shared.terms = vocabularyText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        Vocabulary.shared.save()
                    }
                    Text("\(Vocabulary.shared.learnedCorrections.count) corrections learned automatically").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Behaviour")) {
                Toggle(L("Show the recording overlay"), isOn: $settings.showHUD)
                Toggle(L("Pause Spotify / Music while recording, resume after"), isOn: $settings.pauseMedia)
                Toggle(L("Keep a history of dictations on this Mac"), isOn: $settings.keepDictationHistory)
                Toggle(L("Keep raw meeting audio after transcribing"), isOn: $settings.keepRecordings)
                Toggle(L("Keep the speech model loaded (faster, ~800 MB RAM)"), isOn: $settings.keepModelLoaded)
                    .disabled(settings.asrEngine == "soniox")
                Toggle(L("Start Vocaret at login"), isOn: $settings.startAtLogin)
                    .disabled(!LoginItem.isBundled)
                if !LoginItem.isBundled {
                    Text(L("Available when running the built Vocaret.app (scripts/build_app.sh).")).font(.caption).foregroundStyle(.secondary)
                } else if LoginItem.needsApproval {
                    HStack {
                        Text(L("macOS is waiting for your approval in System Settings → General → Login Items.")).font(.caption).foregroundStyle(.orange)
                        Button(L("Open…")) { LoginItem.openSystemSettings() }.controlSize(.small)
                    }
                }
            }
            Section(L("Permissions")) {
                HStack {
                    Circle().fill(model.accessibilityGranted ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(model.accessibilityGranted ? L("Accessibility granted — text is typed at your cursor") : L("Accessibility missing — transcripts go to the clipboard"))
                    Spacer()
                    if !model.accessibilityGranted { Button(L("Fix…")) { _ = Permissions.accessibilityGranted(promptIfNeeded: true); Permissions.openAccessibilitySettings() } }
                }
                Button(L("Open Microphone settings")) { Permissions.openMicrophoneSettings() }
                Button(L("Open System Audio Recording settings")) { Permissions.openAudioCaptureSettings() }
            }
            Section(L("Data")) {
                LabeledContent(L("Dictation history"), value: TranscriptHistory.shared.fileURL.path)
                LabeledContent(L("Meeting transcripts"), value: SettingsStore.shared.meetingsDir.path)
                LabeledContent(L("Models"), value: SettingsStore.shared.modelsDir.path)
                Text(settings.asrEngine == "soniox"
                     ? L("Live dictation audio is sent to your selected Soniox region. History, meetings, and local cleanup remain on this Mac.")
                     : L("Local speech engines keep audio on this Mac. See PRIVACY.md for the exact details."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Settings"))
        .onAppear {
            settings = SettingsSnapshot()
            vocabularyText = Vocabulary.shared.terms.joined(separator: "\n")
            refreshSonioxKeyStatus()
            model.refreshStatus()
        }
        .onChange(of: settings) { old, new in new.apply(changedFrom: old) }
        .task(id: "\(sonioxKeySaved)-\(settings.sonioxRegion)") {
            if sonioxKeySaved {
                await refreshSonioxUsage()
            } else {
                sonioxUsage = nil
                sonioxUsageStatus = nil
            }
        }
        .onDisappear { recordingHotkey = nil }
        .background(HotkeyRecorder(target: $recordingHotkey) { keyCode, modifiers in
            let label = HotkeyManager.describe(keyCode: keyCode, modifiers: modifiers)
            switch recordingHotkey {
            case .dictation:
                if keyCode == settings.meetingKeyCode, modifiers == settings.meetingModifiers {
                    hotkeyProblem = "“\(label)” " + L("is already the meeting shortcut — choose a different one.")
                } else {
                    settings.dictationKeyCode = keyCode; settings.dictationModifiers = modifiers; hotkeyProblem = nil
                }
            case .meeting:
                if keyCode == settings.dictationKeyCode, modifiers == settings.dictationModifiers {
                    hotkeyProblem = "“\(label)” " + L("is already the dictation shortcut — choose a different one.")
                } else {
                    settings.meetingKeyCode = keyCode; settings.meetingModifiers = modifiers; hotkeyProblem = nil
                }
            case nil: break
            }
            recordingHotkey = nil
        })
    }

    static let knownWhisperModels = [
        "openai_whisper-large-v3-v20240930", "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3",
    ]

    private var speechEngineDescription: String {
        switch settings.asrEngine {
        case "soniox":
            return L("Live words appear while you speak. Audio is processed in your selected Soniox region.")
        case "parakeet":
            return L("Fast local transcription. Best for plain Czech; mixed English terms may be less accurate.")
        default:
            return L("Accurate local transcription. Text appears after a pause or when you finish.")
        }
    }

    private func refreshSonioxKeyStatus() {
        guard !sonioxKeyBusy else { return }
        sonioxKeyBusy = true
        Task { @MainActor in
            defer { sonioxKeyBusy = false }
            do {
                sonioxKeySaved = try await AsyncAPIKeyAccess.shared.load(.soniox) != nil
                sonioxKeyStatus = nil
            } catch {
                sonioxKeySaved = false
                sonioxKeyStatus = error.localizedDescription
            }
        }
    }

    private func saveSonioxKey() {
        guard !sonioxKeyBusy else { return }
        let key = sonioxKeyEntry
        sonioxKeyBusy = true
        Task { @MainActor in
            defer { sonioxKeyBusy = false }
            do {
                try await AsyncAPIKeyAccess.shared.save(key, for: .soniox)
                sonioxKeyEntry = ""
                sonioxKeySaved = true
                sonioxKeyStatus = nil
                model.refreshStatus()
            } catch {
                sonioxKeyStatus = error.localizedDescription
            }
        }
    }

    private func removeSonioxKey() {
        guard !sonioxKeyBusy else { return }
        sonioxKeyBusy = true
        Task { @MainActor in
            defer { sonioxKeyBusy = false }
            do {
                try await AsyncAPIKeyAccess.shared.remove(.soniox)
                sonioxKeyEntry = ""
                sonioxKeySaved = false
                sonioxKeyStatus = nil
                sonioxUsage = nil
                sonioxUsageStatus = nil
                model.refreshStatus()
            } catch {
                sonioxKeyStatus = error.localizedDescription
            }
        }
    }

    @MainActor
    private func refreshSonioxUsage() async {
        guard sonioxKeySaved, !sonioxUsageBusy else { return }
        sonioxUsageBusy = true
        defer { sonioxUsageBusy = false }
        do {
            guard let apiKey = try await AsyncAPIKeyAccess.shared.load(.soniox) else {
                sonioxUsage = nil
                sonioxUsageStatus = L("API key required")
                return
            }
            let region = SonioxRegion(rawValue: settings.sonioxRegion) ?? .eu
            sonioxUsage = try await SonioxUsageClient().fetchCurrentMonth(apiKey: apiKey, region: region)
            sonioxUsageStatus = nil
        } catch {
            sonioxUsageStatus = error.localizedDescription
        }
    }

    private func hotkeyRow(_ title: String, label: String, target: HotkeyTarget) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(recordingHotkey == target ? L("Press a shortcut…") : label)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Button(recordingHotkey == target ? L("Cancel") : L("Change")) {
                recordingHotkey = recordingHotkey == target ? nil : target
                hotkeyProblem = nil
            }
        }
    }
}

public extension Notification.Name {
    static let vocaretUILanguageChanged = Notification.Name("VocaretUILanguageChanged")
}

/// Mirror of SettingsStore so SwiftUI bindings work with plain @State.
struct SettingsSnapshot: Equatable {
    var language = SettingsStore.shared.language
    var autoLanguages = SettingsStore.shared.autoLanguages
    var whisperModel = SettingsStore.shared.whisperModel
    var pushToTalk = SettingsStore.shared.pushToTalk
    var showHUD = SettingsStore.shared.showHUD
    var pauseMedia = SettingsStore.shared.pauseMediaWhileRecording
    var appearance = SettingsStore.shared.appearance
    var asrEngine = SettingsStore.shared.asrEngine
    var sonioxRegion = SettingsStore.shared.sonioxRegion
    var uiLanguage = SettingsStore.shared.uiLanguage
    var cleanDictation = SettingsStore.shared.cleanDictation
    var cleanMeetings = SettingsStore.shared.cleanMeetings
    var keepRecordings = SettingsStore.shared.keepRecordings
    var keepDictationHistory = SettingsStore.shared.keepDictationHistory
    var keepModelLoaded = SettingsStore.shared.keepModelLoaded
    var startAtLogin = LoginItem.isEnabled
    var dictationKeyCode = SettingsStore.shared.dictationKeyCode
    var dictationModifiers = SettingsStore.shared.dictationModifiers
    var meetingKeyCode = SettingsStore.shared.meetingKeyCode
    var meetingModifiers = SettingsStore.shared.meetingModifiers

    var dictationLabel: String { HotkeyManager.describe(keyCode: dictationKeyCode, modifiers: dictationModifiers) }
    var meetingLabel: String { HotkeyManager.describe(keyCode: meetingKeyCode, modifiers: meetingModifiers) }

    /// Write only what the user changed in the form. Writing the whole snapshot
    /// would revert anything toggled elsewhere (menu bar, `defaults`) while the
    /// Settings tab was open — including the appearance and the login item.
    @MainActor
    func apply(changedFrom old: SettingsSnapshot) {
        let s = SettingsStore.shared
        if language != old.language { s.language = language }
        if autoLanguages != old.autoLanguages { s.autoLanguages = autoLanguages }
        if whisperModel != old.whisperModel { s.whisperModel = whisperModel }
        if asrEngine != old.asrEngine {
            s.asrEngine = asrEngine
            Task { await Transcriber.shared.selectEngine(asrEngine) }
        }
        if sonioxRegion != old.sonioxRegion { s.sonioxRegion = sonioxRegion }
        if pushToTalk != old.pushToTalk { s.pushToTalk = pushToTalk }
        if showHUD != old.showHUD { s.showHUD = showHUD }
        if appearance != old.appearance { Appearance.set(appearance) }
        if pauseMedia != old.pauseMedia { s.pauseMediaWhileRecording = pauseMedia }
        if cleanDictation != old.cleanDictation { s.cleanDictation = cleanDictation }
        if cleanMeetings != old.cleanMeetings { s.cleanMeetings = cleanMeetings }
        if keepRecordings != old.keepRecordings { s.keepRecordings = keepRecordings }
        if keepDictationHistory != old.keepDictationHistory { s.keepDictationHistory = keepDictationHistory }
        if keepModelLoaded != old.keepModelLoaded { s.keepModelLoaded = keepModelLoaded }
        if dictationKeyCode != old.dictationKeyCode || dictationModifiers != old.dictationModifiers {
            s.dictationKeyCode = dictationKeyCode; s.dictationModifiers = dictationModifiers
        }
        if meetingKeyCode != old.meetingKeyCode || meetingModifiers != old.meetingModifiers {
            s.meetingKeyCode = meetingKeyCode; s.meetingModifiers = meetingModifiers
        }
        if startAtLogin != old.startAtLogin { LoginItem.setEnabled(startAtLogin) }
        if uiLanguage != old.uiLanguage {
            s.uiLanguage = uiLanguage
            NotificationCenter.default.post(name: .vocaretUILanguageChanged, object: nil)
        }
    }
}

/// Invisible view that, while a target is set, captures the next key chord
/// (with ⌘, ⌃ or ⌥) and reports Carbon keyCode + modifier mask. Esc cancels.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var target: SettingsView.HotkeyTarget?
    let onCapture: (UInt32, UInt32) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        if target != nil, context.coordinator.monitor == nil {
            let cancel = { DispatchQueue.main.async { target = nil } }
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { cancel(); return nil } // Esc
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                var carbon: UInt32 = 0
                if flags.contains(.command) { carbon |= 0x100 }
                if flags.contains(.shift) { carbon |= 0x200 }
                if flags.contains(.option) { carbon |= 0x800 }
                if flags.contains(.control) { carbon |= 0x1000 }
                // Shift alone would make e.g. ⇧A a global hotkey that swallows
                // ordinary typing system-wide — require a real modifier.
                guard carbon & (0x100 | 0x800 | 0x1000) != 0 else { return event }
                DispatchQueue.main.async { onCapture(UInt32(event.keyCode), carbon) }
                return nil
            }
        } else if target == nil {
            context.coordinator.removeMonitor()
        }
    }
    // Without this, leaving Settings mid-recording leaks a monitor that
    // swallows every ⌘/⌥/⌃ keystroke in the window until relaunch.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.removeMonitor() }

    final class Coordinator {
        var monitor: Any?
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { removeMonitor() }
    }
}
