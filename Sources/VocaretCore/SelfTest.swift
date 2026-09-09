import AppKit
import AVFoundation
import Foundation
import SwiftUI
import WhisperKit

/// Hidden headless verification modes that exercise the *real* runtime paths
/// (mic capture, system-audio tap, LLM client, hotkeys, paste) without a
/// human at the keyboard. Speech is synthesized with `say` through the
/// speakers so the microphone / system tap have something to hear.
///
///     Vocaret --selftest mic [seconds] [--out file]
///     Vocaret --selftest tap [seconds] [--out file]
///     Vocaret --selftest llm [--out file]
///     Vocaret --selftest meeting [seconds] [--out file]
///     Vocaret --selftest meeting-stream [--out file]
///     Vocaret --selftest meeting-live [seconds] [--out file]
///     Vocaret --selftest keys [--out file]      (needs Accessibility)
///     Vocaret --selftest all [--out file]
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
            emit("=== Vocaret self-test: \(mode) ===")
            switch mode {
            case "mic": await micTest(seconds: seconds)
            case "tap": await tapTest(seconds: seconds)
            case "llm": await llmTest()
            case "meeting": await meetingTest(seconds: seconds)
            case "meeting-stream": await meetingStreamTest()
            case "meeting-live": await liveMeetingCaptureTest(seconds: seconds)
            case "keys": await keysTest()
            case "hud": await hudTest()
            case "media": await mediaTest()
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
            LLMCleaner.shared.terminateOwnedServer()
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
        emit("[tap] diagnostics: \(tap.diagnostics) sawAudio=\(tap.sawNonZeroSample)")

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
        // Real-world path: warm-up fires when recording starts; the user then
        // speaks for a few seconds; only then is cleanup requested.
        LLMCleaner.shared.terminateOwnedServer()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        emit("[llm] warmUp() at 'recording start', then 4 s of 'speaking'…")
        LLMCleaner.shared.warmUp()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let started = Date()
        let cleaned = await LLMCleaner.shared.cleanDictation(dirty)
        let felt = Date().timeIntervalSince(started)
        emit("[llm] cleanup felt latency after warm-up: \(String(format: "%.2f", felt))s")
        check(felt < 1.5, "[llm] warm cleanup under 1.5 s (was ~3 s cold)")
        let startedSecond = Date()
        _ = await LLMCleaner.shared.cleanDictation("Ten v Hisper zase nefunguje, zeptej se kodexu na revijev.")
        emit("[llm] second cleanup: \(String(format: "%.2f", Date().timeIntervalSince(startedSecond)))s")
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
        let structured = await LLMCleaner.shared.structureMeeting(markdownTranscript: transcript) ?? ""
        emit("[llm] STRUCTURED MEETING:\n\(structured)")
        check(structured.contains("## Summary") || structured.contains("## Shrnutí") || structured.contains("Summary"), "[llm] meeting output has a summary section")
        check(structured.contains("Action") || structured.contains("Akční") || structured.contains("úkoly"), "[llm] meeting output has action items section")

        // Long-meeting path: ~50 turns → several slices → merge pass.
        var long = ""
        for i in 0..<60 {
            let t = String(format: "%02d:%02d", (i * 40) / 60, (i * 40) % 60)
            long += (i % 2 == 0)
                ? "**Me [00:\(t)]:** Bod \(i): probíráme rozpočet na příští kvartál a potřebujeme schválit navýšení o deset procent, protože náklady na infrastrukturu rostou rychleji, než jsme čekali.\n\n"
                : "**Them [00:\(t)]:** Point \(i): I agree in principle, but finance needs a written justification by next Wednesday, and someone has to update the forecast spreadsheet before the board call.\n\n"
        }
        let sliceCount = LLMCleaner.slices(long, maxTokens: LLMCleaner.maxTranscriptTokensPerRequest).count
        emit("[llm] long transcript ~\(LLMCleaner.estimatedTokens(long)) est. tokens → \(sliceCount) slice(s)")
        let started2 = Date()
        let longNotes = await LLMCleaner.shared.structureMeeting(markdownTranscript: long) ?? ""
        emit("[llm] long-meeting structuring took \(String(format: "%.1f", Date().timeIntervalSince(started2)))s:\n\(longNotes.prefix(1200))")
        check(sliceCount >= 2, "[llm] long transcript was sliced")
        check(!longNotes.isEmpty && longNotes.contains("Summary"), "[llm] long-meeting notes produced with a summary")
        check(!longNotes.contains("context limit reached"), "[llm] long-meeting notes not truncated")
    }

    /// Real local inference with synthetic audio streamed at capture cadence.
    /// No microphone, system tap, cloud request, cleanup model, or audio playback.
    @MainActor
    static func meetingStreamTest() async {
        let model = SettingsStore.shared.whisperModel
        let folder = SettingsStore.shared.modelsDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)/TextDecoder.mlmodelc")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            fail("[meeting-stream] selected Whisper model is not cached; test will not download it")
            return
        }
        do {
            let fixture = scratchURL("selftest-stream-fixture.aiff")
            defer { try? FileManager.default.removeItem(at: fixture) }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", fixture.path, englishSample]
            try say.run()
            await Task.detached { say.waitUntilExit() }.value
            guard say.terminationStatus == 0 else {
                fail("[meeting-stream] could not synthesize fixture")
                return
            }
            let speech = try AudioProcessor.loadAudioAsFloatArray(fromPath: fixture.path)
            emit("[meeting-stream] preparing cached local model…")
            await Transcriber.shared.beginMeeting(engine: "whisper")
            var updatesBeforeStop = 0
            let session = MeetingTranscriptionSession(
                decode: { samples, offset in
                    try await Transcriber.shared.transcribeMeetingChunk(samples: samples, offset: offset, engine: "whisper")
                }, onUpdate: { result in
                    await MainActor.run { updatesBeforeStop += 1 }
                    emit("[meeting-stream] live update: \(result.mine.count) mic / \(result.theirs.count) system segments")
                }
            )
            let track = speech + [Float](repeating: 0, count: 48_000)
            for start in stride(from: 0, to: track.count, by: 4_000) {
                let packet = Array(track[start..<min(start + 4_000, track.count)])
                session.append(packet, speaker: .me)
                session.append(packet, speaker: .them)
                try await Task.sleep(for: .milliseconds(250))
            }
            let liveCount = updatesBeforeStop
            let stopped = Date()
            let result = await session.finish()
            let tailSeconds = Date().timeIntervalSince(stopped)
            await Transcriber.shared.endMeeting()
            check(liveCount > 0, "[meeting-stream] transcript arrived before stopping")
            check(!result.mine.isEmpty && !result.theirs.isEmpty, "[meeting-stream] both tracks produced speech")
            check(!result.needsRecovery, "[meeting-stream] no lost audio or recovery")
            emit(String(format: "[meeting-stream] finalization after stop %.3fs; updates before stop %d", tailSeconds, liveCount))
        } catch {
            fail("[meeting-stream] \(error.localizedDescription)")
        }
    }

    /// Actual capture callbacks → bounded live stream → local inference.
    /// Temporary audio is removed and only counts/checks are logged.
    @MainActor
    static func liveMeetingCaptureTest(seconds: Double) async {
        guard #available(macOS 14.4, *) else { fail("[meeting-live] needs macOS 14.4"); return }
        let model = SettingsStore.shared.whisperModel
        let folder = SettingsStore.shared.modelsDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)/TextDecoder.mlmodelc")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            fail("[meeting-live] selected Whisper model is not cached; test will not download it")
            return
        }
        emit("[meeting-live] requesting microphone permission…")
        guard await Permissions.requestMicrophone() else { fail("[meeting-live] microphone denied"); return }
        emit("[meeting-live] preparing cached local model…")
        await Transcriber.shared.beginMeeting(engine: "whisper")
        let micURL = scratchURL("selftest-live-mic-\(UUID().uuidString).wav")
        let systemURL = scratchURL("selftest-live-system-\(UUID().uuidString).wav")
        let tap = SystemAudioTap()
        let mic = MicRecorder()
        let micCount = SampleCounter()
        let systemCount = SampleCounter()
        var updates = 0
        let session = MeetingTranscriptionSession(decode: { samples, offset in
            try await Transcriber.shared.transcribeMeetingChunk(samples: samples, offset: offset, engine: "whisper")
        }, onUpdate: { _ in await MainActor.run { updates += 1 } })
        mic.onSamples = { samples in micCount.append(samples); session.append(samples, speaker: .me) }
        tap.onSamples = { samples in systemCount.append(samples); session.append(samples, speaker: .them) }
        defer {
            tap.stop(); mic.stop()
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)
        }
        do {
            try tap.start(writingTo: systemURL)
            try mic.startToFile(url: micURL)
        } catch {
            session.cancel()
            _ = await session.finish()
            await Transcriber.shared.endMeeting()
            fail("[meeting-live] capture start: \(error.localizedDescription)")
            return
        }
        emit("[meeting-live] capturing real microphone and system audio; playing synthetic speech")
        let speaker = speak(englishSample, voice: nil)
        if let speaker { await Task.detached { speaker.waitUntilExit() }.value }
        try? await Task.sleep(for: .seconds(max(3, seconds)))
        tap.stop(); mic.stop()
        let liveUpdates = updates
        let stopped = Date()
        let result = await session.finish()
        await Transcriber.shared.endMeeting()
        check(micCount.count > 16_000, "[meeting-live] microphone delivered live 16 kHz samples")
        check(systemCount.count > 16_000, "[meeting-live] system tap delivered live 16 kHz samples")
        check(mic.writeFailures == 0 && mic.conversionFailures == 0, "[meeting-live] microphone writes and conversion succeeded")
        check(tap.writeFailures == 0 && tap.conversionFailures == 0 && tap.bufferWrapFailures == 0,
              "[meeting-live] system writes and conversion succeeded")
        check(wavStats(micURL) != nil && wavStats(systemURL) != nil, "[meeting-live] both recovery WAVs readable")
        check(liveUpdates > 0, "[meeting-live] text arrived during capture")
        check(!result.theirs.isEmpty, "[meeting-live] real system audio produced transcript")
        check(!result.needsRecovery, "[meeting-live] no dropped audio or recovery")
        emit(String(format: "[meeting-live] micSamples=%d systemSamples=%d micSegments=%d systemSegments=%d tail=%.3fs",
                    micCount.count, systemCount.count, result.mine.count, result.theirs.count, Date().timeIntervalSince(stopped)))
    }

    private final class SampleCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var samples = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return samples }
        func append(_ chunk: [Float]) { lock.lock(); defer { lock.unlock() }; samples += chunk.count }
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
        try? ("# Self-test meeting\n\n" + (structured ?? raw) + "\n\n---\n\n## Raw transcript\n\n" + raw).write(to: outURL, atomically: true, encoding: .utf8)
        emit("[meeting] wrote \(outURL.path)")
        check(structured != nil, "[meeting] LLM structuring produced notes")
    }

    /// Global hotkey firing + clipboard-swap ⌘V paste into a real NSTextView.
    @MainActor
    static func keysTest() async {
        emit("[keys] checking Accessibility (auto-paste + synthesized keys need it)…")
        var trusted = Permissions.accessibilityGranted(promptIfNeeded: true)
        if !trusted {
            emit("[keys] NOT granted — enable Vocaret in System Settings → Privacy & Security → Accessibility (waiting up to 120s)")
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
        // Use the configured dictation hotkey (default ⌃⌥D — ⌃⌥Space is macOS
        // "next input source" on multi-layout Macs and would switch keyboards).
        let keyCode = SettingsStore.shared.dictationKeyCode
        let modifiers = SettingsStore.shared.dictationModifiers
        do {
            try HotkeyManager.shared.register(id: 77, keyCode: keyCode, modifiers: modifiers) { fired.value = true }
        } catch {
            fail("[keys] hotkey registration threw: \(error)")
        }
        postKey(keyCode: CGKeyCode(keyCode), flags: HotkeyManager.cgFlags(carbonModifiers: modifiers))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        HotkeyManager.shared.unregister(id: 77)
        check(fired.value, "[keys] \(HotkeyManager.describe(keyCode: keyCode, modifiers: modifiers)) global hotkey handler fired")

        // 2. Paste into a real text view in our own window.
        //
        // Vocaret normally runs as an .accessory app and never activates —
        // in real use the ⌘V goes to whatever app the user is already in.
        // To verify the mechanics in-process we must genuinely own the focus,
        // so switch to .regular for this check. If we cannot take focus we
        // must NOT post ⌘V — it would paste into the user's frontmost app.
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }

        // AppKit dispatches ⌘V through the MAIN MENU's Edit▸Paste key
        // equivalent — NSTextView itself does not implement
        // performKeyEquivalent: for it. A menu-bar app has no main menu, so
        // without this the paste could never land in our own window (and a
        // previous run of this test failed for exactly that reason, not
        // because TextInserter was broken). Real target apps have their own
        // Edit▸Paste, which is why ⌘V works there.
        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Vocaret self-test"
        let textView = NSTextView(frame: window.contentView!.bounds)
        textView.isRichText = false
        window.contentView?.addSubview(textView)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)

        // Wait (bounded) until we are genuinely the active app with a key window.
        var focused = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if NSApp.isActive, window.isKeyWindow, window.firstResponder === textView {
                focused = true
                break
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        emit("[keys] focus state: appActive=\(NSApp.isActive) keyWindow=\(window.isKeyWindow) firstResponderIsTextView=\(window.firstResponder === textView) frontmost=\(frontmost)")

        guard focused else {
            fail("[keys] could not focus our own window — skipping the ⌘V check rather than pasting into \(frontmost)")
            window.orderOut(nil)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("ORIGINAL CLIPBOARD", forType: .string)

        let previousShowHUD = SettingsStore.shared.showHUD
        SettingsStore.shared.showHUD = true
        defer { SettingsStore.shared.showHUD = previousShowHUD }
        HUD.shared.beginTranscribing(status: "Cleaning…", hint: "Cancel")
        let payload = "Ahoj světe — pasted by Vocaret"
        let outcome = await TextInserter.insert(payload)
        HUD.shared.hide(immediately: true)
        check(!HUD.shared.isPanelVisible, "[keys] floater closed immediately after insertion")
        emit("[keys] insert outcome: \(outcome)")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        emit("[keys] textview now contains: \"\(textView.string)\"")
        check(outcome.didInsert, "[keys] TextInserter reported insertion")
        check(textView.string.contains(payload), "[keys] payload landed in the focused text view")
        check(pasteboard.string(forType: .string) == "ORIGINAL CLIPBOARD", "[keys] original clipboard restored")

        // Insertion must go to the caret, not replace the field: type a prefix,
        // then insert, and require both to be present in order.
        textView.string = ""
        window.makeFirstResponder(textView)
        textView.insertText("Před: ", replacementRange: NSRange(location: 0, length: 0))
        _ = await TextInserter.insert("vloženo")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        emit("[keys] caret-insert result: \"\(textView.string)\"")
        check(textView.string.contains("Před: vloženo"), "[keys] text inserted at the caret, existing content preserved")

        HUD.shared.beginTranscribing(status: "Finalizing…", hint: "Cancel")
        let beforeFallback = textView.string
        let fallback = await TextInserter.insert("Schránka only", targetPID: -1)
        HUD.shared.hide(immediately: true)
        check(!HUD.shared.isPanelVisible, "[keys] clipboard-only completion closes immediately")
        if case .targetChanged = fallback {
            check(pasteboard.string(forType: .string) == "Schránka only", "[keys] switched-target transcript remains on clipboard")
            check(textView.string == beforeFallback, "[keys] switched-target fallback does not paste")
        } else {
            fail("[keys] expected switched-target clipboard fallback")
        }
        window.orderOut(nil)
    }

    /// Pause-on-record / resume-after with whatever player is running.
    @MainActor
    static func mediaTest() async {
        let pauser = MediaPauser.shared
        let players = pauser.runningPlayers()
        emit("[media] running players: \(players.map(\.name).joined(separator: ", ").isEmpty ? "none" : players.map(\.name).joined(separator: ", "))")
        guard !players.isEmpty else {
            emit("[media] nothing to test — start Spotify or Music and play something, then rerun")
            return
        }
        for p in players {
            emit("[media] \(p.name) automationStatus=\(pauser.automationStatus(p)) state before: \(pauser.playerState(p) ?? "unknown (permission denied?)")")
        }
        var playing = players.filter { pauser.playerState($0) == "playing" }
        // Self-contained: start playback ourselves (we have the app's TCC
        // identity), remember it, and leave the machine quiet afterwards.
        var startedByTest: [MediaPauser.Player] = []
        if playing.isEmpty, let first = players.first {
            emit("[media] nothing playing — starting \(first.name) for the test")
            pauser.send("play", to: first)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            playing = players.filter { pauser.playerState($0) == "playing" }
            startedByTest = playing
        }
        defer { for p in startedByTest { pauser.send("pause", to: p) } }
        guard !playing.isEmpty else {
            emit("[media] no player is playing (couldn't start one) — press play in \(players[0].name) and rerun")
            return
        }
        let paused = await withCheckedContinuation { cont in pauser.pauseIfPlaying { cont.resume(returning: $0) } }
        let pausedSettled = await settles(playing, to: "paused", pauser: pauser)
        for p in playing { emit("[media] \(p.name) state after pause: \(pauser.playerState(p) ?? "?")") }
        check(!paused.isEmpty, "[media] pauseIfPlaying paused the playing app(s)")
        check(pausedSettled, "[media] player reports 'paused' during recording")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let resumed = await withCheckedContinuation { cont in pauser.resumeIfPaused { cont.resume(returning: $0) } }
        let playingSettled = await settles(playing, to: "playing", pauser: pauser)
        for p in playing { emit("[media] \(p.name) state after resume: \(pauser.playerState(p) ?? "?")") }
        check(!resumed.isEmpty, "[media] resumeIfPaused resumed what we paused")
        check(playingSettled, "[media] player is playing again")
        // And the guard: resuming twice must be a no-op (nothing tracked).
        let again = await withCheckedContinuation { cont in pauser.resumeIfPaused { cont.resume(returning: $0) } }
        check(again.isEmpty, "[media] second resume is a no-op")
        // Regression: a dictation shorter than the pause round-trip enqueues
        // the resume immediately behind the pause. The player then still
        // reports (stale) "playing"; the old guard skipped the resume and
        // music stayed paused forever.
        pauser.pauseIfPlaying()
        let rapid = await withCheckedContinuation { cont in pauser.resumeIfPaused { cont.resume(returning: $0) } }
        let rapidSettled = await settles(playing, to: "playing", pauser: pauser)
        check(!rapid.isEmpty, "[media] rapid pause→resume still resumes (stale-state race)")
        check(rapidSettled, "[media] player is playing after the rapid cycle")
    }

    /// Players report `player state` with a lag of up to a second or two after
    /// a command lands (observed on Spotify), so a single read right after a
    /// pause/play proves nothing — poll until it settles.
    private static func settles(
        _ players: [MediaPauser.Player], to expected: String, pauser: MediaPauser, seconds: Double = 6
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if players.allSatisfy({ pauser.playerState($0) == expected }) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    /// Drives the recorder pill through its phases with a synthetic level and
    /// renders each to PNG next to the log — proves the animation path runs.
    @MainActor
    static func hudTest() async {
        let originalShowHUD = SettingsStore.shared.showHUD
        SettingsStore.shared.showHUD = true
        defer { SettingsStore.shared.showHUD = originalShowHUD }
        let dir = (outputURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory)
        var phase = 0.0
        HUD.shared.beginRecording(status: "Live · Soniox", hint: "Release to insert · ⌃⌥D · Esc cancels") {
            phase += 0.09
            return Float(0.35 + 0.35 * sin(phase)) // breathing 0…0.7
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        check(HUD.shared.model.phase == .recording, "[hud] pill entered recording phase")
        HUD.shared.updatePartial("Tohle je živý částečný přepis ze Sonioxu")
        check(!HUD.shared.model.partialText.isEmpty, "[hud] live partial transcript is visible")
        renderPill(to: dir.appendingPathComponent("hud-recording.png"))
        HUD.shared.beginTranscribing(status: "Finalizing…", hint: "Esc cancels")
        check(!HUD.shared.model.partialText.isEmpty, "[hud] finalization preserves the live transcript")
        try? await Task.sleep(nanoseconds: 600_000_000)
        check(HUD.shared.model.phase == .transcribing, "[hud] pill entered transcribing phase")
        renderPill(to: dir.appendingPathComponent("hud-transcribing.png"))
        HUD.shared.setPointerInside(true)
        HUD.shared.hide(immediately: true)
        check(!HUD.shared.isPanelVisible, "[hud] completed dictation closes immediately even while hovered")
        check(HUD.shared.model.partialText.isEmpty, "[hud] completion clears transcript")
        HUD.shared.beginRecording(status: "Next dictation", hint: "Stop", level: { 0 })
        check(HUD.shared.isPanelVisible, "[hud] next dictation reopens floater")
        HUD.shared.setPointerInside(false)
        HUD.shared.flash("Copied — press ⌘V", seconds: 0.4)
        try? await Task.sleep(nanoseconds: 700_000_000)
        check(HUD.shared.model.phase == .hidden, "[hud] flash ended the recording status")
        HUD.shared.setPointerInside(false)
        try? await Task.sleep(for: .seconds(6.3))
        check(!HUD.shared.isPanelVisible, "[hud] idle panel actually disappeared")
        HUD.shared.showCompanion()
        CompanionModel.shared.editingMemory = true
        HUD.shared.resizeCompanion()
        try? await Task.sleep(for: .seconds(6.3))
        check(HUD.shared.isPanelVisible, "[hud] memory editor stays visible beyond idle timeout")
        CompanionModel.shared.editingMemory = false
        HUD.shared.resizeCompanion()
        // Let AppKit finish resizing and deliver any resulting pointer exit.
        try? await Task.sleep(for: .milliseconds(400))
        HUD.shared.setPointerInside(true)
        try? await Task.sleep(for: .seconds(6.3))
        check(HUD.shared.isPanelVisible, "[hud] hovering prevents auto-hide")
        HUD.shared.setPointerInside(false)
        try? await Task.sleep(for: .seconds(6.3))
        check(!HUD.shared.isPanelVisible, "[hud] leaving the idle panel restarts auto-hide")
        let previousShowHUD = SettingsStore.shared.showHUD
        HUD.shared.showCompanion()
        CompanionModel.shared.editingMemory = true
        SettingsStore.shared.showHUD = false
        HUD.shared.hide()
        check(!HUD.shared.isPanelVisible, "[hud] disabling HUD closes even an active memory editor")
        CompanionModel.shared.editingMemory = false
        SettingsStore.shared.showHUD = previousShowHUD
    }

    @MainActor
    private static func renderPill(to url: URL) {
        let view = NSHostingView(rootView: CompanionView(recorder: HUD.shared.model, companion: .shared, app: .shared))
        let size = NSSize(width: 460, height: max(200, view.fittingSize.height))
        view.frame = NSRect(origin: .zero, size: size)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            emit("[hud] rendered \(url.path)")
        }
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
