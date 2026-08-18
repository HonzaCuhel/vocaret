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
                        } label: { Label(copied ? "Copied" : "Copy transcript", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        Button { model.reveal(meeting) } label: { Label("Show in Finder", systemImage: "folder") }
                        Button { NSWorkspace.shared.open(meeting.url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
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
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItem { Button { model.refreshMeetings() } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
            ToolbarItem { Button { NSWorkspace.shared.open(SettingsStore.shared.meetingsDir) } label: { Label("Open folder", systemImage: "folder") } }
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
                        Text("Speaking coach").font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text("Reads your last two weeks of dictation — on this Mac only — and tells you what to work on.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.runCoach()
                    } label: {
                        if model.coachRunning { ProgressView().controlSize(.small).padding(.trailing, 4); Text("Analyzing…") }
                        else { Label(model.coachReport == nil ? "Analyze my speaking" : "Analyze again", systemImage: "sparkles") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.coachRunning || model.records.isEmpty)
                }

                if let report = model.coachReport {
                    metrics(report)
                    section("What I noticed") {
                        ForEach(Array(report.observations.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 8) { Text("→").foregroundStyle(.tint); Text(line) }
                        }
                    }
                    if let advice = report.advice {
                        section("Your coach says") {
                            Text(advice).lineSpacing(3).textSelection(.enabled)
                        }
                    } else {
                        section("Your coach says") {
                            Text(model.llmAvailable
                                 ? "The local model was not reachable — the measurements and reading list above still apply. Try again in a moment."
                                 : "Personal advice needs the local LLM. Run `scripts/setup_llm.sh` once (installs llama.cpp and a 2.4 GB model); everything stays on this Mac.")
                            .foregroundStyle(.secondary)
                        }
                    }
                    section("Worth reading") {
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
                    ContentUnavailableView("Nothing to coach yet", systemImage: "graduationcap", description: Text("Dictate for a day or two, then come back."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    Text("Press *Analyze my speaking*. Measurements are computed locally; the personal note comes from the local LLM if it is set up.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .navigationTitle("Coach")
    }

    private func metrics(_ report: CoachReport) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            StatCard(title: "Filler words", value: String(format: "%.1f%%", report.fillerRate),
                     detail: report.topFillers.prefix(3).joined(separator: ", ").isEmpty ? "of all words" : report.topFillers.prefix(3).joined(separator: ", "), symbol: "ellipsis.bubble")
            StatCard(title: "Sentence length", value: String(format: "%.0f", report.averageSentenceLength), detail: "words on average", symbol: "text.alignleft")
            StatCard(title: "Vocabulary", value: String(format: "%.0f%%", report.vocabularyRichness * 100), detail: "unique words", symbol: "character.book.closed")
            StatCard(title: "Pace", value: report.averageWPM > 0 ? "\(Int(report.averageWPM))" : "—", detail: "words per minute", symbol: "gauge.with.dots.needle.50percent")
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
    @State private var vocabularyText = ""

    enum HotkeyTarget { case dictation, meeting }

    var body: some View {
        Form {
            Section("Shortcuts") {
                hotkeyRow("Dictation", label: settings.dictationLabel, target: .dictation)
                hotkeyRow("Meeting", label: settings.meetingLabel, target: .meeting)
                Toggle("Hold to talk (release inserts); a quick tap toggles", isOn: $settings.pushToTalk)
                Text("Changes to shortcuts apply after you restart Vocaret.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Transcribe", selection: $settings.language) {
                    Text("Auto-detect").tag("auto"); Text("Čeština").tag("cs"); Text("English").tag("en")
                }
                if settings.language == "auto" {
                    Text("Auto-detect chooses between: \(settings.autoLanguages.joined(separator: ", ")). Edit with `defaults write com.jancuhel.vocaret autoLanguages -array cs en de`.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Speech model", selection: $settings.whisperModel) {
                    Text("Large v3 turbo — best for Czech (1.6 GB)").tag("openai_whisper-large-v3-v20240930")
                    Text("Large v3 turbo, compressed (626 MB)").tag("openai_whisper-large-v3-v20240930_626MB")
                    Text("Large v3 — slowest, most accurate (3 GB)").tag("openai_whisper-large-v3")
                }
                Text("A new model downloads on next launch. Smaller models are much worse at Czech.").font(.caption).foregroundStyle(.secondary)
            }
            Section("AI cleanup (local LLM)") {
                Toggle("Clean dictation with AI (adds ~1–2 s)", isOn: $settings.cleanDictation)
                Toggle("Structure meeting notes with AI", isOn: $settings.cleanMeetings)
                HStack {
                    Circle().fill(model.llmAvailable ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(model.llmAvailable ? "llama-server installed" : "Not installed — run scripts/setup_llm.sh in the project folder")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Vocabulary") {
                Text("One term per line. Vocaret always spells these your way, and the AI cleanup is told about them.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $vocabularyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                HStack {
                    Button("Save vocabulary") {
                        Vocabulary.shared.terms = vocabularyText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        Vocabulary.shared.save()
                    }
                    Text("\(Vocabulary.shared.learnedCorrections.count) corrections learned automatically").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Behaviour") {
                Toggle("Show the recording overlay", isOn: $settings.showHUD)
                Toggle("Pause Spotify / Music while recording, resume after", isOn: $settings.pauseMedia)
                Toggle("Keep a history of dictations on this Mac", isOn: $settings.keepDictationHistory)
                Toggle("Keep raw meeting audio after transcribing", isOn: $settings.keepRecordings)
                Toggle("Keep the speech model loaded (faster, ~800 MB RAM)", isOn: $settings.keepModelLoaded)
                Toggle("Start Vocaret at login", isOn: $settings.startAtLogin)
            }
            Section("Permissions") {
                HStack {
                    Circle().fill(model.accessibilityGranted ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(model.accessibilityGranted ? "Accessibility granted — text is typed at your cursor" : "Accessibility missing — transcripts go to the clipboard")
                    Spacer()
                    if !model.accessibilityGranted { Button("Fix…") { _ = Permissions.accessibilityGranted(promptIfNeeded: true); Permissions.openAccessibilitySettings() } }
                }
                Button("Open Microphone settings") { Permissions.openMicrophoneSettings() }
                Button("Open System Audio Recording settings") { Permissions.openAudioCaptureSettings() }
            }
            Section("Data") {
                LabeledContent("Dictation history", value: TranscriptHistory.shared.fileURL.path)
                LabeledContent("Meeting transcripts", value: SettingsStore.shared.meetingsDir.path)
                LabeledContent("Models", value: SettingsStore.shared.modelsDir.path)
                Text("Nothing here ever leaves this Mac. See PRIVACY.md for the exact details.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            settings = SettingsSnapshot()
            vocabularyText = Vocabulary.shared.terms.joined(separator: "\n")
            model.refreshStatus()
        }
        .onChange(of: settings) { _, new in new.apply() }
        .background(HotkeyRecorder(target: $recordingHotkey) { keyCode, modifiers in
            switch recordingHotkey {
            case .dictation: settings.dictationKeyCode = keyCode; settings.dictationModifiers = modifiers
            case .meeting: settings.meetingKeyCode = keyCode; settings.meetingModifiers = modifiers
            case nil: break
            }
            recordingHotkey = nil
        })
    }

    private func hotkeyRow(_ title: String, label: String, target: HotkeyTarget) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(recordingHotkey == target ? "Press a shortcut…" : label)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Button(recordingHotkey == target ? "Cancel" : "Change") {
                recordingHotkey = recordingHotkey == target ? nil : target
            }
        }
    }
}

/// Mirror of SettingsStore so SwiftUI bindings work with plain @State.
struct SettingsSnapshot: Equatable {
    var language = SettingsStore.shared.language
    var autoLanguages = SettingsStore.shared.autoLanguages
    var whisperModel = SettingsStore.shared.whisperModel
    var pushToTalk = SettingsStore.shared.pushToTalk
    var showHUD = SettingsStore.shared.showHUD
    var pauseMedia = SettingsStore.shared.pauseMediaWhileRecording
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

    func apply() {
        let s = SettingsStore.shared
        s.language = language; s.whisperModel = whisperModel; s.pushToTalk = pushToTalk; s.showHUD = showHUD
        s.pauseMediaWhileRecording = pauseMedia
        s.cleanDictation = cleanDictation; s.cleanMeetings = cleanMeetings; s.keepRecordings = keepRecordings
        s.keepDictationHistory = keepDictationHistory; s.keepModelLoaded = keepModelLoaded
        s.dictationKeyCode = dictationKeyCode; s.dictationModifiers = dictationModifiers
        s.meetingKeyCode = meetingKeyCode; s.meetingModifiers = meetingModifiers
        if startAtLogin != LoginItem.isEnabled { LoginItem.setEnabled(startAtLogin) }
    }
}

/// Invisible view that, while a target is set, captures the next key chord
/// (with at least one modifier) and reports Carbon keyCode + modifier mask.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var target: SettingsView.HotkeyTarget?
    let onCapture: (UInt32, UInt32) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        if target != nil, context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                var carbon: UInt32 = 0
                if flags.contains(.command) { carbon |= 0x100 }
                if flags.contains(.shift) { carbon |= 0x200 }
                if flags.contains(.option) { carbon |= 0x800 }
                if flags.contains(.control) { carbon |= 0x1000 }
                guard carbon != 0, event.keyCode != 53 else { return event } // need a modifier; Esc cancels
                DispatchQueue.main.async { onCapture(UInt32(event.keyCode), carbon) }
                return nil
            }
        } else if target == nil, let monitor = context.coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            context.coordinator.monitor = nil
        }
    }
    final class Coordinator { var monitor: Any? }
}
