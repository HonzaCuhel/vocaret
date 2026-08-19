import AppKit

/// Entry point invoked by the executable target.
public enum VocaretMain {
    @MainActor
    public static func run() {
        let arguments = CommandLine.arguments

        // Headless runtime self-tests: `Vocaret --selftest <mic|tap|llm|meeting|keys|all>`
        if SelfTest.runIfRequested(arguments: arguments) {
            return
        }

        // Headless coach run: `Vocaret --coach` → prints the report, caches it for the window
        if arguments.contains("--coach") {
            Task.detached {
                let records = TranscriptHistory.shared.all
                let report = await SpeechCoach.report(records: records) { system, user in
                    await LLMCleaner.shared.generate(system: system, user: user)
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let url = SettingsStore.shared.appSupportDir.appendingPathComponent("coach-report.json")
                try? encoder.encode(report).write(to: url, options: .atomic)
                print("sample=\(report.sampleSize) words=\(report.wordsAnalyzed) fillers=\(String(format: "%.1f", report.fillerRate))% sentence=\(String(format: "%.1f", report.averageSentenceLength)) richness=\(String(format: "%.0f", report.vocabularyRichness * 100))% wpm=\(Int(report.averageWPM))")
                for line in report.observations { print("→ \(line)") }
                print("--- advice ---"); print(report.advice ?? "(LLM unavailable)")
                print("--- books ---"); for book in report.books { print("• \(book.title) — \(book.author)") }
                LLMCleaner.shared.terminateOwnedServer()
                exit(0)
            }
            RunLoop.main.run()
        }

        // Headless UI render: `Vocaret --render-window /dir` → one PNG per section
        if let flagIndex = arguments.firstIndex(of: "--render-window"), arguments.count > flagIndex + 1 {
            WindowRenderer.run(outputDirectory: arguments[flagIndex + 1])
            return
        }

        // Headless verification mode: `Vocaret --transcribe file.wav [--language auto|cs|en]`
        if let flagIndex = arguments.firstIndex(of: "--transcribe"), arguments.count > flagIndex + 1 {
            if let langIndex = arguments.firstIndex(of: "--language"), arguments.count > langIndex + 1 {
                SettingsStore.shared.language = arguments[langIndex + 1]
            }
            if let engineIndex = arguments.firstIndex(of: "--engine"), arguments.count > engineIndex + 1 {
                SettingsStore.shared.asrEngine = arguments[engineIndex + 1]
            }
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
                await Transcriber.shared.preload()
                let started = Date()
                let segments = try await Transcriber.shared.transcribe(
                    fileURL: URL(fileURLWithPath: path)
                )
                FileHandle.standardError.write(Data(String(format: "engine=%@ transcribe=%.2fs\n", SettingsStore.shared.asrEngine, Date().timeIntervalSince(started)).utf8))
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
