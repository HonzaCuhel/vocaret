import SwiftUI

/// A projected 3D particle sphere. Depth controls size, opacity and ordering;
/// voice energy expands the sphere. No assets or continuously running GPU scene.
struct ListeningOrb: View {
    @ObservedObject var recorder: RecorderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || recorder.phase != .recording)) { timeline in
            Canvas { context, size in
                let active = recorder.phase == .recording
                let time = reduceMotion || !active ? 0 : timeline.date.timeIntervalSinceReferenceDate * 0.6
                let energy = reduceMotion ? 0 : Double(max(0, min(1, recorder.levelProvider?() ?? 0)))
                let radius = min(size.width, size.height) * (0.30 + energy * 0.12)
                var points: [(Double, Double, Double)] = []
                for i in 0..<180 {
                    let y = 1 - 2 * Double(i) / 179
                    let ring = sqrt(max(0, 1 - y * y))
                    let angle = Double(i) * 2.399963 + time
                    let x = cos(angle) * ring
                    let z = sin(angle) * ring
                    let rotatedY = y * cos(0.35) - z * sin(0.35)
                    let depth = y * sin(0.35) + z * cos(0.35)
                    points.append((x, rotatedY, depth))
                }
                for (x, y, z) in points.sorted(by: { $0.2 < $1.2 }) {
                    let perspective = 2.8 / (2.8 - z)
                    let dot = 0.7 + (z + 1) * 0.8
                    let rect = CGRect(x: size.width / 2 + x * radius * perspective - dot / 2,
                                      y: size.height / 2 + y * radius * perspective - dot / 2, width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(Color(hue: 0.48 + (z + 1) * 0.13,
                                                                         saturation: 0.5, brightness: 1).opacity(0.22 + (z + 1) * 0.36)))
                }
            }
        }
        .background { Circle().fill(.cyan.opacity(recorder.phase == .recording ? 0.16 : 0.06)).blur(radius: 12).padding(12) }
        .accessibilityLabel(recorder.phase == .recording ? L("Listening") : "Vocaret")
    }
}

struct CompanionView: View {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var companion: CompanionModel
    @ObservedObject var app: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var recording: Bool { recorder.phase == .recording }
    private var processing: Bool { recorder.phase == .transcribing }
    private var expanded: Bool { companion.expanded || companion.mode != .dictation || companion.editingMemory }

    var body: some View {
        VStack(spacing: 10) {
            if expanded { conversationCard }
            controls
        }
        .padding(20)
        .frame(width: 460)
        .preferredColorScheme(.dark)
        .tint(.cyan)
        .onHover { HUD.shared.setPointerInside($0) }
    }

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: companion.editingMemory ? "brain" : "bubble.left.and.bubble.right")
                    .foregroundStyle(.cyan)
                Text(L(companion.editingMemory ? "Memory" : companion.mode == .meeting ? "Live meeting" : "Conversation"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !companion.editingMemory, companion.mode == .chat {
                    Button { companion.clearConversation() } label: { Image(systemName: "plus.bubble") }
                        .help(L("New conversation (clears saved chat)"))
                        .disabled(companion.busy)
                }
                Button { companion.expanded = false; companion.editingMemory = false; companion.mode = .dictation; HUD.shared.resizeCompanion() } label: {
                    Image(systemName: "chevron.down")
                }.help(L("Collapse")).disabled(companion.capturing)
            }
            .foregroundStyle(.secondary)
            if companion.editingMemory {
                Text(L("Shared with the selected agent when you send a message."))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $companion.memoryDraft)
                    .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                    .frame(height: 170).accessibilityLabel(L("Memory document"))
                HStack {
                    Button(L("Cancel")) { companion.closeMemory() }
                    Spacer()
                    Button(L("Save memory")) { companion.saveMemory() }.buttonStyle(.borderedProminent)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if companion.mode == .meeting {
                                if app.liveMeetingTurns.isEmpty {
                                    emptyState("person.2.wave.2", "Both sides. One conversation.", "Microphone + system audio · Transcribed on this Mac")
                                }
                                ForEach(Array(app.liveMeetingTurns.enumerated()), id: \.offset) { _, turn in
                                    bubble(role: L(turn.speaker.label), text: turn.text, mine: turn.speaker == .me)
                                }
                            } else {
                                if companion.messages.isEmpty {
                                    emptyState("sparkles", "A little space to think aloud.", "Speak or type. Your conversation stays here.")
                                }
                                ForEach(companion.messages) { message in
                                    bubble(role: message.role == "user" ? L("You") : "Vocaret", text: message.text, mine: message.role == "user")
                                }
                            }
                            if companion.busy { HStack { ProgressView().controlSize(.small); Text(L("Thinking…")).font(.caption); Spacer(); Button(L("Cancel")) { companion.cancel() } } }
                            Color.clear.frame(height: 1).id("end")
                        }
                    }
                    .frame(height: 190)
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: companion.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: app.liveMeetingTurns.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                if companion.mode == .chat {
                    HStack(spacing: 8) {
                        TextField(L("Ask anything…"), text: $companion.input, axis: .vertical)
                            .lineLimit(1...3).textFieldStyle(.plain)
                            .onSubmit { companion.send() }
                            .accessibilityLabel(L("Message"))
                        Button { companion.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .disabled(companion.busy || companion.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help(L("Send message"))
                    }
                    .padding(10).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Picker(L("Agent"), selection: $companion.agent) {
                            ForEach(CompanionAgent.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 110).disabled(companion.busy)
                        Spacer()
                        Button(L("Propose memory edit")) { companion.send(memoryProposal: true) }
                            .font(.caption).disabled(companion.busy || companion.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(L("Sends chat + Vocaret memory through your signed-in CLI account."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else if companion.mode == .meeting {
                    Text(app.meetingStatus.isEmpty ? L("Start when everyone is ready.") : app.meetingStatus)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Button(L("Open saved meetings")) { app.selectedSection = .meetings; MainWindowController.shared.show() }
                        .font(.caption)
                }
            }
            if let error = companion.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(4)
            }
        }
        .padding(16)
        .background { glass(radius: 22) }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ListeningOrb(recorder: recorder).frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording ? L("Listening") : processing ? L("Transcribing") : "Vocaret")
                        .font(.system(size: 14, weight: .medium))
                    if recording, let started = recorder.startedAt {
                        Text(started, style: .timer).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    } else {
                        Text(L(companion.mode == .chat ? "Keep the conversation going" : companion.mode == .meeting ? "Make room for the meeting" : "Your voice, a little clearer"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if recording || processing {
                    Button { companion.cancelRecording?() } label: { Image(systemName: "xmark") }.help(L("Cancel recording"))
                }
                Button { companion.toggleRecording?() } label: {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16)).foregroundStyle(recording ? .white : .black)
                        .frame(width: 36, height: 36)
                        .background(recording ? Color.red : Color.cyan, in: Circle())
                }.disabled(processing || companion.busy).help(L(recording ? "Finish recording" : "Start recording"))
                Button { HUD.shared.dismissCompanion() } label: { Image(systemName: "minus").foregroundStyle(.secondary) }
                    .help(L("Hide panel (recording continues)"))
            }
            if !recorder.partialText.isEmpty {
                RecorderTranscriptView(transcript: recorder.partialText)
            }
            if !recorder.presentedStatusText.isEmpty {
                Text(recorder.presentedStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if recording, let status = companion.mediaStatus {
                Text(status).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            if companion.mode == .dictation {
                HStack(spacing: 8) {
                    Button {
                        companion.rememberLastDictation()
                        HUD.shared.resizeCompanion()
                    } label: {
                        Label(L("Remember"), systemImage: "brain.head.profile")
                    }
                    .disabled(companion.lastDictation.isEmpty || companion.busy || companion.capturing)
                    .help(L("Review the last dictation before saving it to memory. No agent call."))
                    Spacer(minLength: 0)
                    Text(L("Last dictation · Saved on this Mac"))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.system(size: 11))
                .padding(.vertical, 5)
            }
            HStack(spacing: 4) {
                modeButton(.dictation, "waveform", "Dictate")
                Button { companion.askAboutLastDictation(); HUD.shared.resizeCompanion() } label: {
                    Label(L("Ask assistant"), systemImage: "sparkles").padding(.horizontal, 7).padding(.vertical, 6)
                }.disabled(companion.busy || companion.capturing)
                modeButton(.meeting, "person.2", "Meeting")
                Spacer()
                Button { companion.openMemory(); HUD.shared.resizeCompanion() } label: { Image(systemName: "brain") }
                    .help(L("Edit memory")).disabled(companion.busy || companion.capturing)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background { glass(radius: 24) }
        .buttonStyle(.plain)
        .onChange(of: companion.expanded) { _, _ in HUD.shared.resizeCompanion() }
        .onChange(of: companion.mediaStatus) { _, _ in HUD.shared.resizeCompanion() }
        .onChange(of: companion.error) { _, _ in HUD.shared.resizeCompanion() }
        .onChange(of: companion.input) { _, _ in HUD.shared.resizeCompanion() }
        .onChange(of: companion.busy) { _, _ in HUD.shared.resizeCompanion() }
        .onChange(of: companion.capturing) { _, _ in HUD.shared.resizeCompanion() }
        .onChange(of: companion.editingMemory) { _, _ in HUD.shared.resizeCompanion() }
    }

    private func modeButton(_ mode: CompanionMode, _ icon: String, _ label: String) -> some View {
        Button {
            companion.mode = mode
            companion.expanded = mode != .dictation
            companion.editingMemory = false
            HUD.shared.resizeCompanion()
        } label: {
            Label(L(label), systemImage: icon).padding(.horizontal, 9).padding(.vertical, 6)
                .foregroundStyle(companion.mode == mode ? .white : .gray)
                .background(companion.mode == mode ? .white.opacity(0.09) : .clear, in: Capsule())
        }.disabled(companion.capturing || companion.busy)
    }

    private func bubble(role: String, text: String, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(role).font(.system(size: 10, weight: .medium)).foregroundStyle(mine ? .cyan : .secondary)
            Text(text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(11).frame(maxWidth: 340, alignment: .leading)
        .background(mine ? Color.cyan.opacity(0.08) : Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func emptyState(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(.cyan.opacity(0.7))
            Text(L(title)).font(.system(size: 19, weight: .medium))
            Text(L(detail)).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 30).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func glass(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius).fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: radius).fill(.black.opacity(reduceTransparency ? 1 : 0.30)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.04), .cyan.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }
}
