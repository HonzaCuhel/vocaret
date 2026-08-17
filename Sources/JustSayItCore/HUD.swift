import AppKit

/// Small floating "Recording / Transcribing" pill near the bottom of the
/// active screen. Non-activating, so keyboard focus stays in the user's app.
///
/// Two kinds of message: persistent (`show`/`update`, e.g. "● Recording…")
/// and transient (`flash`). A flash shown while a persistent message is up
/// restores that message when it times out instead of blanking the panel.
@MainActor
public final class HUD {
    public static let shared = HUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    /// The message that should be visible once any transient flash ends.
    private var persistentText: String?
    /// Incremented on every content change so a pending flash timeout never
    /// clobbers a newer message.
    private var generation = 0

    private init() {}

    /// Show a persistent message (until `hide()` or replaced).
    public func show(_ text: String) {
        persistentText = text
        display(text)
    }

    /// Replace the current persistent message.
    public func update(_ text: String) {
        show(text)
    }

    /// Show a transient message; afterwards restore the persistent one (if any) or hide.
    public func flash(_ text: String, seconds: TimeInterval = 2.5) {
        display(text)
        let shownGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == shownGeneration else { return }
            if let persistent = self.persistentText {
                self.display(persistent)
            } else {
                self.hide()
            }
        }
    }

    public func hide() {
        persistentText = nil
        generation += 1
        panel?.orderOut(nil)
    }

    private func display(_ text: String) {
        if panel == nil {
            build()
        }
        generation += 1
        label?.stringValue = text
        layout()
        panel?.orderFrontRegardless()
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 16),
        ])

        panel.contentView = background
        self.panel = panel
        self.label = label
    }

    private func layout() {
        guard let panel, let label else { return }
        label.sizeToFit()
        let width = max(220, label.frame.width + 48)
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.visibleFrame else { return }
        let size = NSSize(width: width, height: 44)
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 96
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
