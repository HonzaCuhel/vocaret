import SwiftUI

/// The state the floating recorder pill renders. Owned by HUD, driven by the
/// controllers; the view re-reads `levelProvider` every frame.
@MainActor
public final class RecorderModel: ObservableObject {
    public enum Phase: Equatable { case hidden, recording, transcribing, message }

    @Published public var phase: Phase = .hidden
    @Published public var text: String = ""
    @Published public var startedAt: Date?
    /// Read on every frame; nil when nothing is recording.
    public var levelProvider: (() -> Float)?

    public init() {}
}

/// Seven capsules that dance with the microphone level while recording,
/// pulse gently while transcribing, and read as a plain status pill otherwise.
public struct RecorderPillView: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 7

    public init(model: RecorderModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 12) {
            indicator
                .frame(width: 44, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if model.phase == .recording, let startedAt = model.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(startedAt)))
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.18), value: model.phase)
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
                .frame(width: 44, height: 22)
            }
            .accessibilityLabel("Recording")
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
                .frame(width: 44, height: 22)
            }
            .accessibilityLabel("Transcribing")
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
