import AppKit
import AVFoundation
import Foundation

/// Hidden headless verification modes that exercise the *real* runtime paths
/// (mic capture, system-audio tap, LLM client, hotkeys, paste) without a
/// human at the keyboard. Speech is synthesized with `say` through the
/// speakers so the microphone / system tap have something to hear.
///
///     JustSayIt --selftest mic [seconds] [--out file]
///     JustSayIt --selftest tap [seconds] [--out file]
///     JustSayIt --selftest llm [--out file]
///     JustSayIt --selftest meeting [seconds] [--out file]
///     JustSayIt --selftest keys [--out file]      (needs Accessibility)
///     JustSayIt --selftest all [--out file]
///
/// Exit code 0 = every requested check passed, 1 = at least one failed.
public enum SelfTest {
    private static let outputLock = NSLock()
    private static var outputURL: URL?
    private static var failures = 0

    static let czechSample = "Dobrý den, toto je zkouška místního přepisu řeči. Zítra máme schůzku v devět hodin ráno."
    static let englishSample = "Hello, this is a test of the local transcription system. Please transcribe this sentence."

    // MARK: - Entry

    /// Returns true if `arguments` requested a self-test (and it has been started).
    @MainActor
    public static func runIfRequested(arguments: [String]) -> Bool {
        guard let flagIndex = arguments.firstIndex(of: "--selftest"), arguments.count > flagIndex + 1 else {
            return false
        }
        let mode = arguments[flagIndex + 1]
        var seconds = 8.0
        if arguments.count > flagIndex + 2, let parsed = Double(arguments[flagIndex + 2]) {
            seconds = parsed
        }
        if let outIndex = arguments.firstIndex(of: "--out"), arguments.count > outIndex + 1 {
            outputURL = URL(fileURLWithPath: arguments[outIndex + 1])
            try? "".write(to: outputURL!, atomically: true, encoding: .utf8)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            emit("=== JustSayIt self-test: \(mode) ===")
            switch mode {
            case "mic": await micTest(seconds: seconds)
            case "tap": await tapTest(seconds: seconds)
            case "llm": await llmTest()
            case "meeting": await meetingTest(seconds: seconds)
            case "keys": await keysTest()
            case "all":
                await micTest(seconds: seconds)
                await tapTest(seconds: seconds)
                await llmTest()
                await meetingTest(seconds: seconds)
                await keysTest()
            default:
                fail("unknown self-test mode '\(mode)'")
            }
            emit("=== DONE: \(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)") ===")
            LLMCleaner.shared.terminateServerNow()
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        return true
    }

    // MARK: - Individual checks

    /// Live microphone → in-memory 16 kHz samples → Whisper.
    @MainActor
    static func micTest(seconds: Double) async {
        emit("[mic] requesting microphone permission…")
        guard await Permissions.requestMicrophone() else {
            fail("[mic] microphone permission denied")
            return
        }
        let recorder = MicRecorder()
        do {
            try recorder.startInMemory()
        } catch {
            fail("[mic] startInMemory threw: \(error)")
            return
        }
        emit("[mic] recording \(Int(seconds))s while speaking Czech through the speakers…")
        let speaker = speak(czechSample, voice: "Zuzana")
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        speaker?.terminate()
        let samples = recorder.stop()

        let peak = samples.map { abs($0) }.max() ?? 0
        emit("[mic] captured \(samples.count) samples = \(String(format: "%.1f", Double(samples.count) / MicRecorder.whisperSampleRate))s, peak amplitude \(String(format: "%.3f", peak))")
        guard samples.count > Int(MicRecorder.whisperSampleRate * seconds * 0.5) else {
            fail("[mic] far fewer samples than expected — converter/tap path broken")
            return
        }
        guard peak > 0.01 else {
            fail("[mic] audio is silent — mic not capturing (headphones plugged in? volume muted?)")
            return
        }
        do {
            let text = try await Transcriber.shared.transcribe(samples: samples)
            emit("[mic] TRANSCRIPT: \(text)")
            check(containsAny(text, ["zkouška", "přepis", "schůzk", "devět"]), "[mic] transcript contains expected Czech words")
        } catch {
            fail("[mic] transcription threw: \(error)")
        }
    }

    /// System-audio process tap → WAV → Whisper (the "Them" side of meetings).
    @MainActor
    static func tapTest(seconds: Double) async {
        guard #available(macOS 14.4, *) else {
            fail("[tap] macOS < 14.4")
            return
        }
        let url = scratchURL("selftest-tap.wav")
        let tap = SystemAudioTap()
        do {
            try tap.start(writingTo: url)
        } catch {
            fail("[tap] start threw: \(error)")
            return
        }
        emit("[tap] capturing system audio \(Int(seconds))s while playing English through the speakers…")
        let speaker = speak(englishSample, voice: nil)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        speaker?.terminate()
        tap.stop()
        emit("[tap] diagnostics: \(tap.diagnostics)")

        guard let (duration, peak) = wavStats(url) else {
            fail("[tap] output WAV unreadable")
            return
        }
        emit("[tap] WAV duration \(String(format: "%.1f", duration))s, peak amplitude \(String(format: "%.3f", peak))")
        guard duration > seconds * 0.5 else {
            fail("[tap] WAV much shorter than capture window — IO proc not delivering")
            return
        }
        guard peak > 0.001 else {
            fail("[tap] captured audio is silent — System Audio Recording permission missing?")
            return
        }
        do {
            let segments = try await Transcriber.shared.transcribe(fileURL: url)
            let text = segments.map(\.text).joined(separator: " ")
            emit("[tap] TRANSCRIPT: \(text)")
            check(containsAny(text, ["test", "transcription", "sentence"]), "[tap] transcript contains expected English words")
        } catch {
            fail("[tap] transcription threw: \(error)")
        }
    }

    /// The app's own llama-server client: spawn, health-poll, chat, idle state.
    @MainActor
    static func llmTest() async {
        let dirty = "no takže ehm zítra máme jako schůzku v devět a ehm potřebuju abys mi vlastně poslal ten report jo"
        emit("[llm] cleanDictation via LLMCleaner (spawns llama-server if needed)…")
        let started = Date()
        let cleaned = await LLMCleaner.shared.cleanDictation(dirty)
        emit("[llm] took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        emit("[llm] IN : \(dirty)")
        emit("[llm] OUT: \(cleaned)")
        check(cleaned != dirty, "[llm] output differs from input (server reachable, model answered)")
        check(!cleaned.lowercased().contains("ehm"), "[llm] filler 'ehm' removed")
        check(cleaned.contains("schůzk"), "[llm] stayed in Czech")
        check(LLMCleaner.shared.processBox.isRunning, "[llm] llama-server child process is running after the call")

        let transcript = """
        **Me [00:00:01]:** Ahoj, tak začneme. Potřebujeme dokončit report do pátku.
        **Them [00:00:08]:** OK, I can finish the data section by Thursday.
        **Me [00:00:14]:** Super, já udělám úvod a závěr.
        """
        let structured = await LLMCleaner.shared.structureMeeting(markdownTranscript: transcript)
        emit("[llm] STRUCTURED MEETING:\n\(structured)")
        check(structured.contains("## Summary") || structured.contains("## Shrnutí") || structured.contains("Summary"), "[llm] meeting output has a summary section")
        check(structured.contains("Action") || structured.contains("Akční") || structured.contains("úkoly"), "[llm] meeting output has action items section")
    }

    /// Full meeting pipeline minus hotkey/HUD: both tracks → transcribe → merge → (LLM) → markdown.
    @MainActor
    static func meetingTest(seconds: Double) async {
        guard #available(macOS 14.4, *) else {
            fail("[meeting] macOS < 14.4")
            return
        }
        guard await Permissions.requestMicrophone() else {
            fail("[meeting] microphone permission denied")
            return
        }
        let micURL = scratchURL("selftest-meeting-mic.wav")
        let sysURL = scratchURL("selftest-meeting-system.wav")
        let tap = SystemAudioTap()
        let mic = MicRecorder()
        do {
            try tap.start(writingTo: sysURL)
            try mic.startToFile(url: micURL)
        } catch {
            fail("[meeting] start threw: \(error)")
            tap.stop()
            mic.stop()
            return
        }
        emit("[meeting] recording both tracks \(Int(seconds))s (Czech then English through speakers)…")
        let first = speak(czechSample, voice: "Zuzana")
        first?.waitUntilExit()
        let second = speak(englishSample, voice: nil)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        second?.terminate()
        tap.stop()
        mic.stop()

        if let (d, p) = wavStats(micURL) { emit("[meeting] mic WAV \(String(format: "%.1f", d))s peak \(String(format: "%.3f", p))") } else { fail("[meeting] mic WAV unreadable") }
        if let (d, p) = wavStats(sysURL) { emit("[meeting] system WAV \(String(format: "%.1f", d))s peak \(String(format: "%.3f", p))") } else { fail("[meeting] system WAV unreadable") }

        let mine = (try? await Transcriber.shared.transcribe(fileURL: micURL)) ?? []
        let theirs = (try? await Transcriber.shared.transcribe(fileURL: sysURL)) ?? []
        emit("[meeting] mic segments: \(mine.count), system segments: \(theirs.count)")
        check(!mine.isEmpty, "[meeting] mic track produced segments")
        check(!theirs.isEmpty, "[meeting] system track produced segments")

        let turns = TranscriptMerger.merge(mine: mine, theirs: theirs)
        let raw = TranscriptMerger.markdown(turns: turns)
        emit("[meeting] RAW MERGED TRANSCRIPT:\n\(raw)")
        check(raw.contains("**Me ["), "[meeting] merged transcript has Me lines")
        check(raw.contains("**Them ["), "[meeting] merged transcript has Them lines")

        let structured = await LLMCleaner.shared.structureMeeting(markdownTranscript: raw)
        let outURL = scratchURL("selftest-meeting.md")
        try? ("# Self-test meeting\n\n" + structured + "\n\n---\n\n## Raw transcript\n\n" + raw).write(to: outURL, atomically: true, encoding: .utf8)
        emit("[meeting] wrote \(outURL.path)")
        check(structured != raw, "[meeting] LLM structuring changed the transcript")
    }

    /// Global hotkey firing + clipboard-swap ⌘V paste into a real NSTextView.
    @MainActor
    static func keysTest() async {
        emit("[keys] checking Accessibility (auto-paste + synthesized keys need it)…")
        var trusted = Permissions.accessibilityGranted(promptIfNeeded: true)
        if !trusted {
            emit("[keys] NOT granted — enable JustSayIt in System Settings → Privacy & Security → Accessibility (waiting up to 120s)")
            for _ in 0..<60 where !trusted {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                trusted = Permissions.accessibilityGranted(promptIfNeeded: false)
            }
        }
        guard trusted else {
            fail("[keys] Accessibility still not granted — hotkey/paste checks skipped")
            return
        }
        emit("[keys] Accessibility granted")

        // 1. Hotkey: register ⌃⌥Space, synthesize the keystroke, expect the handler.
        let fired = Flag()
        do {
            try HotkeyManager.shared.register(id: 77, keyCode: 49, modifiers: 0x1800) { fired.value = true }
        } catch {
            fail("[keys] hotkey registration threw: \(error)")
        }
        postKey(keyCode: 49, flags: [.maskControl, .maskAlternate])
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        HotkeyManager.shared.unregister(id: 77)
        check(fired.value, "[keys] ⌃⌥Space global hotkey handler fired")

        // 2. Paste: a real text view in our own window receives the ⌘V.
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "JustSayIt self-test"
        let textView = NSTextView(frame: window.contentView!.bounds)
        textView.isRichText = false
        window.contentView?.addSubview(textView)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        try? await Task.sleep(nanoseconds: 700_000_000)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("ORIGINAL CLIPBOARD", forType: .string)

        let payload = "Ahoj světe — pasted by JustSayIt"
        let pasted = TextInserter.insert(payload)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        emit("[keys] textview now contains: \"\(textView.string)\"")
        check(pasted, "[keys] TextInserter reported paste")
        check(textView.string.contains(payload), "[keys] payload landed in the focused text view via ⌘V")
        check(pasteboard.string(forType: .string) == "ORIGINAL CLIPBOARD", "[keys] original clipboard restored")
        window.orderOut(nil)
    }

    // MARK: - Helpers

    private final class Flag { var value = false }

    private static func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    @discardableResult
    private static func speak(_ text: String, voice: String?) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args: [String] = []
        if let voice { args += ["-v", voice] }
        args.append(text)
        process.arguments = args
        do {
            try process.run()
            return process
        } catch {
            emit("[warn] could not run `say`: \(error)")
            return nil
        }
    }

    private static func wavStats(_ url: URL) -> (duration: Double, peak: Float)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return (duration, 0)
        }
        try? file.read(into: buffer)
        var peak: Float = 0
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                let data = UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength))
                peak = max(peak, data.map { abs($0) }.max() ?? 0)
            }
        }
        return (duration, peak)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        let lower = text.lowercased()
        return needles.contains { lower.contains($0.lowercased()) }
    }

    private static func scratchURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    static func check(_ condition: Bool, _ what: String) {
        if condition {
            emit("PASS  \(what)")
        } else {
            fail(what)
        }
    }

    static func fail(_ what: String) {
        failures += 1
        emit("FAIL  \(what)")
    }

    static func emit(_ line: String) {
        outputLock.lock()
        defer { outputLock.unlock() }
        print(line)
        fflush(stdout)
        if let outputURL, let handle = try? FileHandle(forWritingTo: outputURL) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }
}
