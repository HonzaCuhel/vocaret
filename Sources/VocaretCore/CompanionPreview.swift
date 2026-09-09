import AppKit
import SwiftUI

@MainActor
enum CompanionPreview {
    static func run(directory: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vocaret-preview-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let companion = CompanionModel(directory: temporary)
                let recorder = RecorderModel()
                for mode in ["listening", "conversation", "meeting", "memory"] {
                    companion.mode = mode == "meeting" ? .meeting : mode == "listening" ? .dictation : .chat
                    companion.expanded = mode != "listening"
                    companion.editingMemory = mode == "memory"
                    companion.memoryDraft = "# Vocaret memory\n\n- Odpovídej stručně a česky.\n- Aktuální projekt: zahrada.\n- Rozhodnutí vždy odděl od návrhů."
                    companion.messages = [
                        .init(role: "user", text: "Pojďme navázat na ten návrh zahrady. Co jsme si domluvili?"),
                        .init(role: "assistant", text: "Jabloně u plotu a bylinky blízko kuchyně. Zbývá vybrat místo pro hrušeň. Chceš projít možnosti?"),
                        .init(role: "user", text: "Ano, a pamatuj si, že na terase chci odpoledne stín.")
                    ]
                    companion.input = "Navrhni úpravu paměti…"
                    AppModel.shared.liveMeetingTurns = [
                        .init(speaker: .me, start: 0, text: "První verzi bych chtěl vyzkoušet ve čtvrtek."),
                        .init(speaker: .them, start: 4, text: "Souhlasím. Připravím ukázku a projdeme ji společně."),
                        .init(speaker: .me, start: 9, text: "Dobře, poznámky po schůzce zůstanou tady.")
                    ]
                    AppModel.shared.meetingStatus = L("Listening — speech appears after a short pause")
                    recorder.phase = mode == "memory" ? .hidden : .recording
                    recorder.startedAt = Date().addingTimeInterval(-42)
                    recorder.levelProvider = { 0.65 }
                    recorder.partialText = mode == "listening" ? "Stačí mluvit. Myšlenky mají kam plynout." : ""
                    let view = CompanionView(recorder: recorder, companion: companion, app: .shared)
                    let hosting = NSHostingView(rootView: view)
                    hosting.frame = NSRect(x: 0, y: 0, width: 460, height: mode == "listening" ? 250 : 640)
                    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.18, alpha: 1)
                    window.contentView = hosting
                    window.orderBack(nil)
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(400))
                    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CompanionError.message("Cannot render") }
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]) else { throw CompanionError.message("Cannot encode PNG") }
                    try png.write(to: output.appendingPathComponent("\(mode).png"))
                    print("Rendered \(mode)")
                    window.orderOut(nil)
                }
                exit(0)
            } catch { print(error.localizedDescription); exit(1) }
        }
        app.run()
    }
}
