import AppKit
import SwiftUI

/// Headless verification: render every section of the main window to PNG.
/// `Vocaret --render-window /output/dir` — no permissions needed, so it works
/// from a script and doubles as a visual-regression check.
@MainActor
enum WindowRenderer {
    static func run(outputDirectory: String) {
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            for section in MainSection.allCases {
                AppModel.shared.selectedSection = section
                let hosting = NSHostingView(rootView: MainView().environmentObject(AppModel.shared))
                hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
                hosting.appearance = NSAppearance(named: .aqua)
                hosting.wantsLayer = true
                hosting.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = hosting
                window.orderBack(nil) // must be in a window for layout to happen
                hosting.layoutSubtreeIfNeeded()
                // Give SwiftUI a couple of runloop turns to settle charts/lists.
                try? await Task.sleep(nanoseconds: 400_000_000)
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        let url = dir.appendingPathComponent("\(section.rawValue).png")
                        try? png.write(to: url)
                        print("rendered \(url.path)")
                    }
                }
                window.orderOut(nil)
            }
            exit(0)
        }
        app.run()
    }
}
