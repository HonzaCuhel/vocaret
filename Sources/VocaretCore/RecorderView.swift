import SwiftUI
import AppKit

enum RecorderTranscriptPresentation {
    static let companionWidth: CGFloat = 392
    static let companionFont = NSFont.systemFont(ofSize: 14)

    struct Presentation {
        let text: String
        let height: CGFloat
    }

    static func visibleText(_ transcript: String) -> String {
        presentation(transcript).text
    }

    /// Measure the newest lines with the same TextKit settings used to render
    /// them. Sentence counts cannot bound a long, unpunctuated live partial.
    static func presentation(
        _ transcript: String,
        width: CGFloat = companionWidth,
        font: NSFont = companionFont,
        lineLimit: Int = 3
    ) -> Presentation {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Presentation(text: "", height: 0) }

        // Keep layout work bounded as the full recording grows. This is far
        // more than the 3–4 lines either recorder view can display; String's
        // suffix preserves composed characters, including Czech and emoji.
        var visible = String(trimmed.suffix(2_048))
        let storage = NSTextStorage(string: visible, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)

        var lineRanges: [NSRange] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, range, _ in
            lineRanges.append(range)
        }
        if lineRanges.count > max(1, lineLimit) {
            let firstVisibleLine = lineRanges[lineRanges.count - max(1, lineLimit)]
            let characters = manager.characterRange(forGlyphRange: firstVisibleLine, actualGlyphRange: nil)
            visible = (visible as NSString).substring(from: characters.location)
            storage.setAttributedString(NSAttributedString(string: visible, attributes: [.font: font]))
            manager.ensureLayout(for: container)
        }
        return Presentation(text: visible, height: ceil(manager.usedRect(for: container).maxY))
    }

    static func shouldCenter(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        return !trimmed.isEmpty && words <= 3 && trimmed.count <= 32
    }
}

/// The measured suffix is rendered by TextKit too, so SwiftUI's multiline
/// truncation cannot hide its newest words or substitute a tail ellipsis.
struct RecorderTranscriptView: View {
    let transcript: String
    var width: CGFloat = RecorderTranscriptPresentation.companionWidth
    var font: NSFont = RecorderTranscriptPresentation.companionFont
    var lineLimit: Int = 3
    var alignment: NSTextAlignment = .left

    var body: some View {
        let presentation = RecorderTranscriptPresentation.presentation(transcript, width: width, font: font, lineLimit: lineLimit)
        RecorderTranscriptTextView(text: presentation.text, font: font, alignment: alignment)
            .frame(width: width, height: presentation.height)
            .accessibilityLabel(L("Live transcript"))
    }
}

private struct RecorderTranscriptTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let alignment: NSTextAlignment

    func makeNSView(context: Context) -> NSTextView {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]))
    }
}

/// The state the floating recorder pill renders. Owned by HUD, driven by the
/// controllers; the view re-reads `levelProvider` every frame.
@MainActor
public final class RecorderModel: ObservableObject {
    public enum Phase: Equatable { case hidden, recording, transcribing, message }

    @Published public var phase: Phase = .hidden
    @Published public var statusText: String = ""
    @Published public var hintText: String = ""
    @Published public var partialText: String = ""
    @Published public var startedAt: Date?
    private var initialRecordingStatus: String?
    /// Read on every frame; nil when nothing is recording.
    public var levelProvider: (() -> Float)?

    public init() {}

    /// Compatibility for callers that still treat the primary copy as one
    /// message. New recorder flows should set status and hint separately.
    public var text: String {
        get { statusText }
        set { statusText = newValue }
    }

    /// Recording already has an animated microphone indicator. Repeating the
    /// engine name (for example, "Live · Soniox" or "Local transcription")
    /// adds noise without helping the user; phase changes still show status.
    var presentedStatusText: String {
        phase == .recording && statusText == initialRecordingStatus ? "" : statusText
    }

    var presentedPartialText: String {
        RecorderTranscriptPresentation.visibleText(partialText)
    }

    var centersPresentedPartialText: Bool {
        RecorderTranscriptPresentation.shouldCenter(presentedPartialText)
    }

    func beginRecording() {
        partialText = ""
    }

    func beginRecording(status: String, hint: String) {
        beginRecording()
        statusText = status
        initialRecordingStatus = status
        hintText = hint
        phase = .recording
    }

    func beginTranscribing(status: String, hint: String) {
        statusText = status
        hintText = hint
        phase = .transcribing
    }

    func endInteraction() {
        statusText = ""
        hintText = ""
        partialText = ""
        initialRecordingStatus = nil
    }
}

/// A compact status row with a prominent rolling transcript underneath.
public struct RecorderPillView: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 7

    public init(model: RecorderModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                indicator
                    .frame(width: 36, height: 22)

                if !model.presentedStatusText.isEmpty {
                    Text(model.presentedStatusText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                if model.phase == .recording, let startedAt = model.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(startedAt)))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.hintText.isEmpty {
                    Text(model.hintText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !model.partialText.isEmpty {
                RecorderTranscriptView(
                    transcript: model.partialText,
                    width: 496,
                    font: .systemFont(ofSize: 17, weight: .medium),
                    lineLimit: 4,
                    alignment: model.centersPresentedPartialText ? .center : .left
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(width: 528, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.10))
        )
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .recording:
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
                let level = CGFloat(model.levelProvider?() ?? 0)
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(Color.red.gradient)
                            .frame(width: 4, height: barHeight(index: index, level: level, time: t))
                    }
                }
                .frame(width: 36, height: 22)
            }
            .accessibilityLabel(L("Recording"))
        case .transcribing:
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let phase = sin(t * 3.2 + Double(index) * 0.55)
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.gradient)
                            .frame(width: 4, height: 6 + 8 * CGFloat(phase * 0.5 + 0.5))
                    }
                }
                .frame(width: 36, height: 22)
            }
            .accessibilityLabel(L("Transcribing"))
        case .message, .hidden:
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// Centre bars swing most; each bar carries a little independent motion so
    /// a steady voice still looks alive rather than like a static level meter.
    private func barHeight(index: Int, level: CGFloat, time: TimeInterval) -> CGFloat {
        let centre = CGFloat(barCount - 1) / 2
        let distance = abs(CGFloat(index) - centre) / centre        // 0 at centre, 1 at edges
        let envelope = 1 - 0.55 * distance
        let wobble = reduceMotion ? 0 : CGFloat(sin(time * (7 + Double(index))) * 0.12)
        let amplitude = max(0, min(1, level * envelope + wobble * level))
        return 4 + amplitude * 18
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
