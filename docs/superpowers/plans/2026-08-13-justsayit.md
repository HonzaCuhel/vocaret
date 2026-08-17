# Utter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Deviation note:** authored and executed inline in the same autonomous session (`/goal` mode, no user available to choose execution mode). Tasks below carry exact files/interfaces/commands; full code lives in the commits, spec in `docs/superpowers/specs/2026-08-13-utter-design.md`.

**Goal:** Free, fully-local macOS menu-bar app: hotkey dictation (cs/en) pasted at the caret, meeting transcription (mic + system audio) with local-LLM cleanup.

**Architecture:** SwiftPM executable bundled as `Utter.app` (LSUIElement). WhisperKit (CoreML/ANE) for ASR, Carbon hotkeys, AVAudioEngine mic capture, Core Audio process tap for system audio, `llama-server` subprocess (Qwen3-4B GGUF) for cleanup.

**Tech Stack:** Swift 5.10 language mode (Swift 6.2 toolchain), AppKit, WhisperKit ≥ 0.9, CoreAudio, Carbon HIToolbox, llama.cpp (brew), Qwen3-4B-Instruct-2507 Q4_K_M.

## Global Constraints

- macOS 14+ platform target; process-tap code gated `#available(macOS 14.4, *)`.
- Default Whisper model: `openai_whisper-large-v3-v20240930_626MB`; fallback `openai_whisper-small`.
- Default hotkeys: dictation `⌃⌥Space`, meeting `⌃⌥M`, cancel `Esc` (only while recording).
- All model/data paths under `~/Library/Application Support/Utter/`; meeting outputs under `~/Documents/Utter/Meetings/`.
- No network calls at runtime except localhost llama-server; downloads only in setup script / first model fetch.
- RAM: Whisper stays loaded (setting `keepModelLoaded`, default true); llama-server killed after 120 s idle.

---

### Task 1: Package scaffold + SettingsStore

**Files:** Create `Package.swift`, `Sources/Utter/main.swift` (temporary stub), `Sources/Utter/SettingsStore.swift`, `Tests/UtterTests/SettingsStoreTests.swift`, `.gitignore`.

**Interfaces (produces):**
- `SettingsStore.shared` — `var language: String` ("auto"|"cs"|"en"), `var whisperModel: String`, `var cleanDictation: Bool` (false), `var cleanMeetings: Bool` (true), `var keepRecordings: Bool` (true), `var keepModelLoaded: Bool` (true), `var dictationKeyCode/dictationModifiers/meetingKeyCode/meetingModifiers: UInt32`, `var llamaServerPath: String?`, `var llmModelPath: String?`, `var llmPort: Int` (8765), computed `var appSupportDir/meetingsDir: URL` (created on access).

- [ ] Write `Package.swift` (swift-tools-version 5.10, platform .macOS(.v14), dep WhisperKit from 0.9.0) and stub sources; start `swift package resolve` in background.
- [ ] Write SettingsStore + tests (defaults, round-trip via UserDefaults suite injected for tests).
- [ ] `swift test` passes. Commit.

### Task 2: TranscriptMerger (TDD, pure logic)

**Files:** Create `Sources/Utter/TranscriptMerger.swift`, `Tests/UtterTests/TranscriptMergerTests.swift`.

**Interfaces (produces):**
- `struct SpokenSegment { var start: Double; var end: Double; var text: String }`
- `enum Speaker { case me, them }` with `var label: String` ("Me"/"Them")
- `TranscriptMerger.merge(mine: [SpokenSegment], theirs: [SpokenSegment], coalesceGap: Double = 2.0) -> [MergedTurn]` where `struct MergedTurn { var speaker: Speaker; var start: Double; var text: String }`
- `TranscriptMerger.markdown(turns: [MergedTurn]) -> String` — `**Me [hh:mm:ss]:** text` lines.

- [ ] Failing tests: chronological interleave, same-speaker coalescing (< gap), no-coalesce across speaker change, empty-track handling, whitespace/empty-segment dropping, timestamp formatting ≥ 1 h.
- [ ] Run: `swift test --filter TranscriptMergerTests` → FAIL (type not found). Implement. → PASS. Commit.

### Task 3: Audio capture (mic + WAV writing)

**Files:** Create `Sources/Utter/MicRecorder.swift`, `Sources/Utter/WavFileWriter.swift`, `Tests/UtterTests/WavFileWriterTests.swift`.

**Interfaces (produces):**
- `final class MicRecorder` — `func startInMemory() throws` (16 kHz mono Float32 accumulation), `func startToFile(url: URL) throws` (native-format WAV via AVAudioFile), `func stop() -> [Float]` (returns samples for in-memory mode; empty for file mode), `var isRunning: Bool`.
- `WavFileWriter` is only a thin test-covered helper if AVAudioFile alone suffices; drop if redundant (YAGNI check at implementation time).

- [ ] Tests for whatever pure helpers exist (e.g. converter format math); AVAudioEngine paths are integration-verified in Task 10.
- [ ] `swift build` clean. Commit.

### Task 4: Transcriber (WhisperKit wrapper)

**Files:** Create `Sources/Utter/Transcriber.swift`.

**Interfaces (produces):**
- `actor Transcriber` — `func preload() async`, `func transcribe(samples: [Float]) async throws -> String`, `func transcribe(fileURL: URL) async throws -> [SpokenSegment]`, `func unload()`, `var isReady: Bool`.
- Language resolution: `SettingsStore.language == "auto"` → `DecodingOptions(language: nil, detectLanguage: true)` else forced code. VAD chunking for files.

- [ ] Implement with configured-model → fallback-model error path and 1 s silence warm-up. `swift build` clean. Commit. (Real inference verified in Task 10.)

### Task 5: Dictation UX (hotkeys, HUD, status item, controller)

**Files:** Create `Sources/Utter/HotkeyManager.swift`, `Sources/Utter/HUD.swift`, `Sources/Utter/StatusItemController.swift`, `Sources/Utter/DictationController.swift`, `Sources/Utter/AppDelegate.swift`; replace `main.swift` stub with NSApplication bootstrap.

**Interfaces:**
- Consumes: `MicRecorder`, `Transcriber`, `SettingsStore`, later `TextInserter`.
- Produces: `HotkeyManager` — `func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws`, `func unregister(id: UInt32)`; `HUD.show(_ text: String)/hide()`; `DictationController` — `func toggle()`, `func cancel()`, `var state: DictationState` (`idle/recording/transcribing`).

- [ ] Implement; menu shows state, Start/Stop Dictation, Start/Stop Meeting (stub), language submenu with checkmarks, toggles (Clean dictation with AI, Keep recordings), Open Transcripts Folder, Quit.
- [ ] `swift build` clean; app runs as bare executable (menu bar icon appears). Commit.

### Task 6: TextInserter

**Files:** Create `Sources/Utter/TextInserter.swift`, `Sources/Utter/Permissions.swift`.

**Interfaces (produces):**
- `enum TextInserter { static func insert(_ text: String) }` — Accessibility granted → clipboard-swap + ⌘V CGEvent + restore; else clipboard + `NSUserNotification`-successor (UNUserNotificationCenter unavailable unbundled → use NSAlert-free banner via HUD text) fallback.
- `Permissions.ensureAccessibility(prompt: Bool) -> Bool`, `Permissions.microphoneStatus`.

- [ ] Implement; wire into DictationController completion. `swift build` clean. Commit.

### Task 7: Meeting mode (system audio tap + controller)

**Files:** Create `Sources/Utter/SystemAudioTap.swift`, `Sources/Utter/MeetingController.swift`.

**Interfaces:**
- `final class SystemAudioTap` — `func start(writingTo url: URL) throws`, `func stop()`; gated `@available(macOS 14.4, *)`; tap → aggregate device → IOProc → AVAudioFile.
- `final class MeetingController` — `func toggle()`, `var state: MeetingState` (`idle/recording/processing`); on stop: transcribe mic.wav + system.wav → `TranscriptMerger` → optional `LLMCleaner.structureMeeting` → write markdown to meetingsDir → reveal in Finder.

- [ ] Implement; wire menu + `⌃⌥M`. `swift build` clean. Commit.

### Task 8: LLMCleaner (llama-server client) + prompts

**Files:** Create `Sources/Utter/LLMCleaner.swift`, `Sources/Utter/LLMPrompts.swift`, `Tests/UtterTests/LLMPromptsTests.swift`.

**Interfaces (produces):**
- `actor LLMCleaner` — `func cleanDictation(_ text: String) async -> String` (returns input on any failure), `func structureMeeting(markdownTranscript: String) async -> String` (idem), `func shutdown()`.
- `LLMPrompts.dictationSystem`, `LLMPrompts.meetingSystem`, `LLMPrompts.meetingUser(transcript:) -> String` — language-preserving (cs stays cs, en stays en), tested for key invariants (mentions both languages, forbids translation, forbids adding facts).
- Server lifecycle: spawn if port closed, `/health` poll ≤ 20 s, kill after 120 s idle via DispatchSourceTimer.

- [ ] TDD the prompt builders; implement client; wire into Dictation/Meeting controllers behind settings flags. `swift test` passes. Commit.

### Task 9: Packaging + setup scripts

**Files:** Create `scripts/build_app.sh`, `scripts/setup_llm.sh`, `Resources/Info.plist` (template), `README.md`.

- [ ] `build_app.sh`: `swift build -c release` → assemble `build/Utter.app` (Info.plist: CFBundleIdentifier `com.jancuhel.utter`, LSUIElement, NSMicrophoneUsageDescription, NSAudioCaptureUsageDescription, LSMinimumSystemVersion 14.4) → `codesign --force -s -` → optional `--install` to `~/Applications`.
- [ ] `setup_llm.sh`: brew install llama.cpp if missing; curl Qwen3-4B-Instruct-2507-Q4_K_M.gguf (unsloth GGUF repo) to Models dir with resume; write resolved paths into UserDefaults via `defaults write com.jancuhel.utter`.
- [ ] README: features, setup, permissions walkthrough (Mic, Accessibility, System Audio Recording), hotkeys, RAM notes, troubleshooting. Commit.

### Task 10: Verification & delivery

- [ ] `swift test` — all green.
- [ ] `scripts/build_app.sh` — bundle builds, codesign verifies (`codesign -dv`).
- [ ] Run `scripts/setup_llm.sh` (downloads ~2.4 GB) and prefetch Whisper model; CLI smoke: transcribe a generated test WAV (say/ffmpeg synthesized Czech + English sample) via a hidden `--selftest` flag on the executable; verify llama-server round-trip.
- [ ] Launch app, verify menu bar presence. Document what needs the user's one-time permission clicks. Final commit.
