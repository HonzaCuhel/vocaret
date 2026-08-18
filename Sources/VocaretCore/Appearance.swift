import AppKit

/// Light / dark / follow-system for the whole app (window, HUD, menus).
public enum Appearance {
    public static let options: [(id: String, title: String)] = [
        ("system", "Follow System"), ("light", "Light"), ("dark", "Dark"),
    ]

    @MainActor
    public static func apply(_ id: String) {
        switch id {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    @MainActor
    public static func set(_ id: String) {
        SettingsStore.shared.appearance = id
        apply(id)
    }
}
