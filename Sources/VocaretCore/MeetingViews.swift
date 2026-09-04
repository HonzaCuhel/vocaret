import AppKit
import SwiftUI

/// Meeting navigation keeps a running conversation one click away while older
/// transcripts remain readable. Only the selected file is loaded into the detail.
struct MeetingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: MeetingFile.ID?
    @State private var search = ""

    private var isActive: Bool { model.meetingState != .idle }
    private var matches: [MeetingFile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.meetings }
        return model.meetings.filter {
            $0.title.localizedStandardContains(query) || $0.preview.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                library
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                detail
                    .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L("Meetings"))
        .toolbar {
            ToolbarItemGroup {
                Button { model.refreshMeetings() } label: {
                    Label(L("Refresh"), systemImage: "arrow.clockwise")
                }
                .help(L("Refresh"))
                Button { NSWorkspace.shared.open(SettingsStore.shared.meetingsDir) } label: {
                    Label(L("Open folder"), systemImage: "folder")
                }
                .help(L("Open folder"))
            }
        }
        .onAppear {
            model.refreshMeetings()
            if !isActive, selection == nil { selection = model.meetings.first?.id }
        }
        .onChange(of: model.meetingState) { oldState, newState in
            if newState != .idle {
                selection = nil
            } else if oldState != .idle {
                selection = nil
                model.refreshMeetings()
            }
        }
        .onChange(of: model.meetings) { _, meetings in
            if !isActive, selection == nil || !meetings.contains(where: { $0.id == selection }) {
                selection = meetings.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("Meetings"))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Label(L("Processed on this Mac"), systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !isActive, !model.meetingStatus.isEmpty {
                    Text(model.meetingStatus)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                        .help(model.meetingStatus)
                }
            }
            Spacer(minLength: 8)
            MeetingActionButton(state: model.meetingState, action: model.toggleMeeting)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isActive {
                Button { selection = nil } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.meetingState == .recording ? "waveform" : "ellipsis.bubble")
                            .font(.title3)
                            .foregroundStyle(model.meetingState == .recording ? Color.red : Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("Current meeting")).fontWeight(.semibold)
                            Text(L(model.meetingState == .recording ? "Recording" : "Finalizing…"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(selection == nil ? Color.accentColor.opacity(0.11) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == nil ? .isSelected : [])
                .padding(10)
            }

            HStack {
                Text(L("Saved meetings")).font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.meetings.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, isActive ? 4 : 18)
            .padding(.bottom, 10)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search meetings"), text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L("Search meetings"))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Clear search"))
                }
            }
            .padding(8)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if matches.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L(search.isEmpty ? "No saved meetings yet" : "No matching meetings"))
                        .font(.callout.weight(.medium))
                    Text(L(search.isEmpty ? "Your finished transcripts appear here." : "Try another title or preview phrase."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                Spacer()
            } else {
                List(matches, selection: $selection) { meeting in
                    MeetingLibraryRow(meeting: meeting).tag(meeting.id)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    @ViewBuilder private var detail: some View {
        if let meeting = model.meetings.first(where: { $0.id == selection }) {
            SavedMeetingDetail(meeting: meeting)
                .id(meeting.id)
        } else if isActive {
            LiveMeetingPanel(state: model.meetingState, startedAt: model.meetingStartedAt,
                             turns: model.liveMeetingTurns, status: model.meetingStatus,
                             copy: model.copy)
        } else {
            VStack(spacing: 18) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(L("Stay in the conversation"))
                        .font(.title2.weight(.semibold))
                    Text(L("Capture both sides of your call. Follow the transcript as you speak, then revisit it here."))
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(SettingsStore.shared.meetingHotkeyLabel)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(L("Meeting shortcut") + ": " + SettingsStore.shared.meetingHotkeyLabel)
            }
            .padding(30)
            .frame(maxWidth: 440, maxHeight: .infinity)
        }
    }
}

private struct MeetingActionButton: View {
    let state: MeetingController.State
    let action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 7) {
                if state == .processing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state == .recording ? "stop.fill" : "record.circle")
                }
                Text(L(state == .recording ? "Finish meeting" : state == .processing ? "Finalizing…" : "Start meeting"))
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.borderedProminent)
        .tint(state == .recording ? Color.red : Color.accentColor)
        .controlSize(.large)
        .disabled(state == .processing || action == nil)
    }
}

private struct MeetingLibraryRow: View {
    let meeting: MeetingFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title).font(.callout.weight(.semibold)).lineLimit(2)
            Text(meeting.preview.replacingOccurrences(of: "**", with: ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Text(meeting.date, format: .dateTime.day().month(.abbreviated))
                Text("·")
                Text(meeting.wordCount.formatted() + " " + L("words"))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

/// This view accepts values so its empty, recording and finishing states can
/// be rendered without starting capture or changing any user preferences.
struct LiveMeetingPanel: View {
    let state: MeetingController.State
    let startedAt: Date?
    let turns: [MergedTurn]
    let status: String
    var copy: (String) -> Void
    @State private var followLatest = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Label(L(state == .recording ? "Recording" : "Finalizing…"),
                          systemImage: state == .recording ? "record.circle.fill" : "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state == .recording ? Color.red : Color.accentColor)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background((state == .recording ? Color.red : Color.accentColor).opacity(0.09),
                                    in: Capsule())
                    Spacer()
                    if let startedAt, state == .recording {
                        Text(startedAt, style: .timer)
                            .font(.system(.callout, design: .monospaced)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L("Elapsed time"))
                    }
                }
                Text(L("Live transcript"))
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                HStack(alignment: .top, spacing: 7) {
                    if state == .processing { ProgressView().controlSize(.mini) }
                    Text(status.isEmpty ? L("Listening to your microphone and call audio…") : status)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(L("Processed on this Mac"), systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            if turns.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tint).accessibilityHidden(true)
                    Text(L(state == .recording ? "Ready when you speak" : "Finishing your transcript"))
                        .font(.headline)
                    Text(L("Speech appears here in short passages, with each side of the call labeled."))
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(turns.indices, id: \.self) { index in
                                MeetingTurnView(turn: turns[index])
                            }
                            Color.clear.frame(height: 1).id("latest-turn")
                        }
                        .padding(24)
                    }
                    .onAppear { if followLatest { proxy.scrollTo("latest-turn", anchor: .bottom) } }
                    .onChange(of: turns) { _, _ in
                        if followLatest { proxy.scrollTo("latest-turn", anchor: .bottom) }
                    }
                    .onChange(of: followLatest) { _, follow in
                        if follow { proxy.scrollTo("latest-turn", anchor: .bottom) }
                    }
                }
            }

            Divider()
            ViewThatFits(in: .horizontal) {
                HStack {
                    followToggle
                    Spacer()
                    copyButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    followToggle
                    copyButton
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
    }

    private var followToggle: some View {
        Toggle(L("Follow latest"), isOn: $followLatest)
            .toggleStyle(.switch).controlSize(.mini)
            .help(L("Scroll to new speech automatically"))
    }

    private var copyButton: some View {
        Button {
            copy(TranscriptMerger.markdown(turns: turns))
            copied = true
        } label: {
            Label(L(copied ? "Copied" : "Copy transcript"), systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(turns.isEmpty)
    }
}

private struct MeetingTurnView: View {
    let turn: MergedTurn

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: turn.speaker == .me ? "person.fill" : "person.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(turn.speaker == .me ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)
                .background(turn.speaker == .me ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(L(turn.speaker.label)).font(.callout.weight(.semibold))
                    Text(TranscriptMerger.timestamp(turn.start))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(turn.text)
                    .font(.system(size: 14)).lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SavedMeetingDetail: View {
    @EnvironmentObject var model: AppModel
    let meeting: MeetingFile
    @State private var text = ""
    @State private var bodyText = ""
    @State private var isLoading = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(meeting.title).font(.title2.weight(.semibold))
                    .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Text(meeting.date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    Text("·")
                    Text(meeting.wordCount.formatted() + " " + L("words"))
                }
                .font(.caption).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { copyButton; openButton; revealButton }
                    HStack(spacing: 8) {
                        copyButton
                        openButton.labelStyle(.iconOnly)
                        revealButton.labelStyle(.iconOnly)
                    }
                }
            }
            .padding(24)
            Divider()
            ScrollView {
                if isLoading {
                    ProgressView(L("Loading transcript…"))
                        .controlSize(.small).padding(24)
                } else if text.isEmpty {
                    Text(L("This transcript is empty or could not be read."))
                        .foregroundStyle(.secondary).padding(24)
                } else {
                    MarkdownText(bodyText)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: meeting) {
            isLoading = true
            let url = meeting.url
            let loaded = await Task.detached(priority: .userInitiated) {
                let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                // The title is already presented above the reader. Prepare the
                // body off the main actor too, including for long meetings.
                let lines = raw.components(separatedBy: "\n")
                let body = lines.first?.hasPrefix("# ") == true ? lines.dropFirst().joined(separator: "\n") : raw
                return (raw, body)
            }.value
            guard !Task.isCancelled else { return }
            text = loaded.0
            bodyText = loaded.1
            isLoading = false
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
    }

    private var copyButton: some View {
        Button { model.copy(text); copied = true } label: {
            Label(L(copied ? "Copied" : "Copy transcript"), systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(isLoading || text.isEmpty)
    }

    private var openButton: some View {
        Button { NSWorkspace.shared.open(meeting.url) } label: {
            Label(L("Open"), systemImage: "arrow.up.forward.app")
        }
        .help(L("Open"))
    }

    private var revealButton: some View {
        Button { model.reveal(meeting) } label: {
            Label(L("Show in Finder"), systemImage: "folder")
        }
        .help(L("Show in Finder"))
    }
}
