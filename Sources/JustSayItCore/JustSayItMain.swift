import AppKit

/// Entry point invoked by the executable target.
public enum JustSayItMain {
    @MainActor
    public static func run() {
        let arguments = CommandLine.arguments

        // Headless verification mode: `JustSayIt --transcribe file.wav`
        if let flagIndex = arguments.firstIndex(of: "--transcribe"), arguments.count > flagIndex + 1 {
            runTranscribeCLI(path: arguments[flagIndex + 1])
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
        app.run()
    }

    private static func runTranscribeCLI(path: String) {
        Task.detached {
            do {
                let segments = try await Transcriber.shared.transcribe(
                    fileURL: URL(fileURLWithPath: path)
                )
                for segment in segments {
                    print(String(format: "[%7.2f – %7.2f] %@", segment.start, segment.end, segment.text))
                }
                if segments.isEmpty {
                    print("(no speech recognized)")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Transcription failed: \(error)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}
