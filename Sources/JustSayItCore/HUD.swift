import AppKit

/// Small floating "Recording / Transcribing" pill near the bottom of the
/// active screen. Non-activating, so keyboard focus stays in the user's app.
@MainActor
public final class HUD {
    public static let shared = HUD()

    private var panel: NSPanel?
    private var label: NSTextField?

    private init() {}

    public func show(_ text: String) {
        if panel == nil {
            build()
        }
        label?.stringValue = text
        layout()
        panel?.orderFrontRegardless()
    }

    public func update(_ text: String) {
        guard panel?.isVisible == true else {
            show(text)
            return
        }
        label?.stringValue = text
        layout()
    }

    public func flash(_ text: String, seconds: TimeInterval = 2.5) {
        show(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.hide()
        }
    }

    public func hide() {
        panel?.orderOut(nil)
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
