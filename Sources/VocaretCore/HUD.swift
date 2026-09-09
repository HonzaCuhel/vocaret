import AppKit
import SwiftUI

/// Floating recorder pill near the bottom of the active screen. Non-activating,
/// so keyboard focus stays in the user's app. Renders `CompanionView`; while
/// recording it animates with the live microphone level.
///
/// Two kinds of message: persistent (`show`/`update`, e.g. "● Recording…")
/// and transient (`flash`).
@MainActor
public final class HUD {
    public static let shared = HUD()

    public let model = RecorderModel()

    private var panel: NSPanel?
    private var hosting: NSHostingView<CompanionView>?
    private var companionVisible = false
    private var persistentText: String?
    private var generation = 0

    private init() {}

    // MARK: - Recording lifecycle (drives the animation)

    /// Enter the recording phase; `level` is polled every frame.
    public func beginRecording(status: String, hint: String, level: @escaping () -> Float) {
        model.beginRecording(status: status, hint: hint)
        model.levelProvider = level
        model.startedAt = Date()
        persistentText = status
        present()
    }

    public func beginTranscribing(status: String, hint: String) {
        model.levelProvider = nil
        model.beginTranscribing(status: status, hint: hint)
        persistentText = status
        present()
    }

    // MARK: - Messages

    /// Show a persistent message (until `hide()` or replaced).
    public func show(_ text: String) {
        persistentText = text
        if model.phase == .hidden {
            model.phase = .message
            model.hintText = ""
        }
        model.statusText = text
        present()
    }

    /// Replace the current persistent message.
    public func update(_ text: String) { show(text) }

    /// Replaceable live recognition text shown below the persistent status.
    public func updatePartial(_ text: String) {
        guard model.phase == .recording || model.phase == .transcribing else { return }
        model.partialText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        layout()
    }

    public func clearPartial() {
        model.partialText = ""
        layout()
    }

    /// Show a transient message and then hide. A flash always ENDS the current
    /// interaction, so it clears the persistent message rather than restoring it.
    public func flash(_ text: String, seconds: TimeInterval = 2.5) {
        persistentText = nil
        model.endInteraction()
        model.levelProvider = nil
        model.phase = .message
        model.statusText = text
        present()
        let shownGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == shownGeneration else { return }
            self.hide()
        }
    }

    public func hide() {
        persistentText = nil
        generation += 1
        model.levelProvider = nil
        model.startedAt = nil
        model.endInteraction()
        model.phase = .hidden
        if companionVisible && SettingsStore.shared.showHUD { present() } else { panel?.orderOut(nil) }
    }

    func showCompanion() {
        companionVisible = true
        SettingsStore.shared.showHUD = true
        present()
    }

    func dismissCompanion() {
        companionVisible = false
        panel?.orderOut(nil)
    }

    func resizeCompanion() {
        layout()
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    private func present() {
        guard SettingsStore.shared.showHUD else { return }
        if panel == nil { build() }
        generation += 1
        layout()
        panel?.orderFrontRegardless()
    }

    private func build() {
        let panel = CompanionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the SwiftUI pill draws its own
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: CompanionView(recorder: model, companion: .shared, app: .shared))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hosting.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        panel.contentView = container
        self.panel = panel
        self.hosting = hosting
    }

    private func layout() {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.visibleFrame else { return }
        let companion = CompanionModel.shared
        let expanded = companion.expanded || companion.mode != .dictation || companion.editingMemory
        let fittingHeight = hosting?.fittingSize.height ?? 0
        let height = fittingHeight > 80 ? fittingHeight : (expanded ? 640 : 220)
        let size = NSSize(width: 460, height: min(screenFrame.height, height))
        let previous = panel.frame
        let x = panel.isVisible ? previous.minX : screenFrame.midX - size.width / 2
        let y = panel.isVisible ? previous.minY : screenFrame.minY + 60
        let origin = NSPoint(x: min(max(x, screenFrame.minX), screenFrame.maxX - size.width),
                             y: min(max(y, screenFrame.minY), screenFrame.maxY - size.height))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
