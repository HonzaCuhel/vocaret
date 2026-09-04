import AppKit
import SwiftUI

/// Headless verification: render every section of the main window to PNG.
/// `Vocaret --render-window /output/dir` — no permissions needed, so it works
/// from a script and doubles as a visual-regression check.
@MainActor
enum WindowRenderer {
    static func run(outputDirectory: String, meetingPreviewsOnly: Bool = false) {
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            // A synthetic-only run does not instantiate AppModel or load any
            // existing dictations, meeting files or coach reports.
            for section in meetingPreviewsOnly ? [] : MainSection.allCases {
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
            // Fictional data only: verify the active meeting states without
            // microphone access, audio capture, disk transcripts or preferences.
            let sampleTurns = [
                MergedTurn(speaker: .me, start: 3,
                           text: "Let's focus on the first release. The transcript should already be useful while we're still on the call."),
                MergedTurn(speaker: .them, start: 14,
                           text: "Agreed. Keep the conversation easy to follow, and make it clear which parts are still being processed."),
                MergedTurn(speaker: .me, start: 26,
                           text: "I'll check the live view today. We can review the saved notes together tomorrow.")
            ]
            for (name, appearance, state) in [
                ("Meetings-live-light", NSAppearance.Name.aqua, MeetingController.State.recording),
                ("Meetings-live-dark", NSAppearance.Name.darkAqua, MeetingController.State.recording),
                ("Meetings-finishing", NSAppearance.Name.aqua, MeetingController.State.processing)
            ] {
                let panel = LiveMeetingPanel(
                    state: state, startedAt: Date().addingTimeInterval(-42), turns: sampleTurns,
                    status: L(state == .recording ? "Listening to your microphone and call audio…" : "Finishing your transcript"),
                    copy: { _ in }
                )
                let hosting = NSHostingView(rootView: panel)
                hosting.frame = NSRect(x: 0, y: 0, width: 650, height: 540)
                hosting.appearance = NSAppearance(named: appearance)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                window.orderBack(nil)
                hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(400))
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        let url = dir.appendingPathComponent("\(name).png")
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
