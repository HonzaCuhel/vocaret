import AppKit
import WhisperKit

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

        // Benchmarks the REAL dictation path (samples in, cleaned text out),
        // which differs from --transcribe: it uses the single-window decode
        // and the sticky language, then the LLM cleanup if it is enabled.
        // `Vocaret --bench-dictation clip.wav [--repeat 3]`
        if let flagIndex = arguments.firstIndex(of: "--bench-dictation"), arguments.count > flagIndex + 1 {
            var repeats = 3
            if let index = arguments.firstIndex(of: "--repeat"), arguments.count > index + 1 {
                repeats = Int(arguments[index + 1]) ?? 3
            }
            if let engineIndex = arguments.firstIndex(of: "--engine"), arguments.count > engineIndex + 1 {
                SettingsStore.shared.asrEngine = arguments[engineIndex + 1]
            }
            runDictationBench(path: arguments[flagIndex + 1], repeats: repeats)
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
        app.run()
    }

    private static func runDictationBench(path: String, repeats: Int) {
        Task.detached {
            do {
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
                let seconds = Double(samples.count) / MicRecorder.whisperSampleRate
                await Transcriber.shared.preload()
                let cleanup = SettingsStore.shared.cleanDictation
                FileHandle.standardError.write(Data(String(
                    format: "clip=%.1fs engine=%@ cleanup=%@ repeats=%d\n",
                    seconds, SettingsStore.shared.asrEngine, cleanup ? "on" : "off", repeats).utf8))
                // Where would the early-transcription trigger fire if this clip
                // had been spoken live? Replays the buffer in 250 ms steps.
                var firedAt: [Double] = []
                var speculated = 0
                var step = Int(0.25 * MicRecorder.whisperSampleRate)
                if step < 1 { step = 1 }
                var cursor = step
                while cursor < samples.count {
                    let prefix = Array(samples[0..<cursor])
                    if SpeechPause.shouldSpeculate(on: prefix, alreadySpeculatedCount: speculated) {
                        speculated = prefix.count
                        firedAt.append(Double(cursor) / MicRecorder.whisperSampleRate)
                    }
                    cursor += step
                }
                let covered = speculated > 0 && SpeechPause.covers(speculated, of: samples)
                FileHandle.standardError.write(Data(String(
                    format: "early-decode: fires at [%@]s, last covers whole clip: %@\n",
                    firedAt.map { String(format: "%.2f", $0) }.joined(separator: ", "),
                    covered ? "yes" : "no").utf8))

                for run in 1...max(1, repeats) {
                    // Exactly what a recording start does.
                    if cleanup { LLMCleaner.shared.warmUp() }
                    try? await Task.sleep(nanoseconds: UInt64(min(seconds, 4) * 1_000_000_000))
                    let started = Date()
                    let raw = try await Transcriber.shared.transcribe(samples: samples)
                    let transcribed = Date()
                    let text = cleanup ? await LLMCleaner.shared.cleanDictation(raw) : raw
                    let done = Date()
                    FileHandle.standardError.write(Data(String(
                        format: "run %d: asr=%.2fs cleanup=%.2fs total=%.2fs | %@\n",
                        run,
                        transcribed.timeIntervalSince(started),
                        done.timeIntervalSince(transcribed),
                        done.timeIntervalSince(started),
                        text.replacingOccurrences(of: "\n", with: " ")).utf8))
                }
                LLMCleaner.shared.terminateOwnedServer()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("bench failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        NSApplication.shared.run()
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
