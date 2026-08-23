import SwiftUI

enum RecorderTranscriptPresentation {
    static func visibleText(_ transcript: String, sentenceLimit: Int = 4) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var sentences: [String] = []
        trimmed.enumerateSubstrings(
            in: trimmed.startIndex..<trimmed.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let sentence = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        guard !sentences.isEmpty else { return trimmed }
        return sentences.suffix(max(1, sentenceLimit)).joined(separator: " ")
    }

    static func shouldCenter(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        return !trimmed.isEmpty && words <= 3 && trimmed.count <= 32
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
        phase == .recording ? "" : statusText
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

            if !model.presentedPartialText.isEmpty {
                Text(model.presentedPartialText)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .truncationMode(.head)
                    .multilineTextAlignment(model.centersPresentedPartialText ? .center : .leading)
                    .frame(
                        maxWidth: .infinity,
                        alignment: model.centersPresentedPartialText ? .center : .leading
                    )
                    .accessibilityLabel(L("Live transcript"))
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
