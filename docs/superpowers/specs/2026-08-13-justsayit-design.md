# JustSayIt — Local Speech-to-Text for macOS (Design)

**Date:** 2026-08-13
**Status:** Approved autonomously (session running under `/goal` — user unavailable for interactive review; decisions recorded here for later review).

## Purpose

A free, fully-local Wispr Flow / SuperWhisper replacement for personal use:

1. **Dictation** — press a global hotkey, speak (Czech or English), press again; the transcript is typed into whatever app/text field currently has the keyboard caret.
2. **Meeting transcription** — capture *both* the microphone (what I say) and system audio (what I hear, e.g. Google Meet) and produce a labeled, cleaned, structured transcript.
3. **LLM cleanup** — a small local LLM fixes punctuation, removes filler words, and structures meeting transcripts (summary + action items).

Constraints: free, 100 % local/offline after setup, fast, RAM-efficient (18 GB machine), Czech + English.

## Environment

Apple M3 Pro, 18 GB RAM, macOS 26.2, Xcode 26.3 / Swift 6.2.4, Homebrew, ~23 GB free disk. No Ollama.

## Approaches considered

| Approach | Verdict |
|---|---|
| **A. Native Swift menu-bar app + WhisperKit (CoreML/ANE) + llama.cpp subprocess** | ✅ Chosen. Lowest RAM, fastest inference (ANE), no Python runtime, pure SwiftPM build. |
| B. Python (faster-whisper / mlx-whisper + pynput + rumps) | Rejected: ~400 MB+ Python runtime overhead, fragile TCC permissions on interpreter binaries, slower cold start. |
| C. whisper.cpp CLI + Hammerspoon glue | Rejected: model reload per invocation kills latency; no clean meeting-capture story. |

## Architecture

Menu-bar-only app (`LSUIElement`), SwiftPM executable bundled into `JustSayIt.app` by a build script. No sandbox (personal tool; needed for CGEvent paste + process tap).

```
HotkeyManager (Carbon RegisterEventHotKey — no special permission)
    │ toggle
    ▼
DictationController ──► MicRecorder (AVAudioEngine → 16 kHz mono Float32 in memory)
    │ stop                      │
    ▼                           ▼
Transcriber (WhisperKit, model preloaded, ANE) ──► TextInserter (clipboard + ⌘V CGEvent, restore clipboard)
                                                        │ optional
                                                        ▼
                                             LLMCleaner (llama-server subprocess, on-demand)

MeetingController ──► MicRecorder → mic.wav (native rate)
                 └──► SystemAudioTap (Core Audio process tap + aggregate device) → system.wav
    │ stop
    ▼
Transcriber (per file, word timestamps) ──► TranscriptMerger (Me/Them, chronological, coalesced)
    ▼
LLMCleaner (structure: summary, action items, cleaned transcript)
    ▼
~/Documents/JustSayIt/Meetings/<date>.md  (+ raw WAVs kept per setting)
```

### Components

- **HotkeyManager** — Carbon hotkeys: `⌃⌥Space` dictation toggle, `⌃⌥M` meeting toggle, `Esc` (registered only while recording) cancels. Chosen over `⌥Space` to avoid Raycast/Alfred conflicts. Configurable via `UserDefaults` (keyCode + modifiers).
- **MicRecorder** — AVAudioEngine input tap; converts to 16 kHz mono Float32 via AVAudioConverter for dictation (in-memory, ~3.8 MB/min); writes native-rate WAV for meetings.
- **SystemAudioTap** — `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` + `AudioHardwareCreateProcessTap` + private aggregate device with the tap in its tap list; IOProc writes to WAV. Requires `NSAudioCaptureUsageDescription`. macOS 14.4+ only (we're on 26.x).
- **Transcriber** — WhisperKit wrapper. Default model `openai_whisper-large-v3-v20240930_626MB` (quantized turbo, multilingual — handles Czech well). Fallback to `openai_whisper-small` if load fails. Preloaded at launch + 1 s silence warm-up so first dictation is instant. Language: `auto` (per-utterance detection) or forced cs/en via menu. Models stored under `~/Library/Application Support/JustSayIt/Models`.
- **TextInserter** — saves clipboard, sets transcript, posts ⌘V via CGEvent (needs Accessibility), restores clipboard after 0.5 s. If Accessibility not granted: leaves text on clipboard + user notification "press ⌘V".
- **LLMCleaner** — spawns `llama-server` (brew llama.cpp) on `127.0.0.1:8765` with Qwen3-4B-Instruct-2507 Q4_K_M GGUF (~2.4 GB), talks OpenAI-compatible `/v1/chat/completions`, kills the server after 120 s idle so RAM returns to zero. Dictation cleanup is **off by default** (adds latency); meeting structuring **on by default**.
- **TranscriptMerger** — pure function: two segment lists (mic="Me", system="Them") → chronologically sorted, consecutive same-speaker segments < 2 s apart coalesced → markdown. Unit-tested.
- **HUD** — small non-activating floating NSPanel showing "● Recording" / "Transcribing…"; menu-bar icon mirrors state. Start/stop sounds.
- **SettingsStore** — UserDefaults: model name, language (auto/cs/en), cleanDictation, cleanMeetings, keepRecordings, hotkey codes, LLM paths.

### Error handling

- Model load failure → fallback model → user notification with reason.
- Hotkey registration conflict → notification suggesting alternate combo.
- No Accessibility → clipboard fallback + notification (never silently drop a transcript).
- llama-server missing/fails → skip cleanup, deliver raw transcript, notify.
- Meeting stop → transcription runs async; partial failure (e.g. system track empty) still yields the other track.

### RAM budget

Idle with model loaded: ~700–900 MB (mostly mmapped CoreML weights, reclaimable). Optional auto-unload of Whisper after 10 min idle (default on for meetings-only users, setting `keepModelLoaded` default true). LLM: 0 when idle, ~2.8 GB during a cleanup job, freed 120 s after.

### Testing

- `swift test`: TranscriptMerger (ordering, coalescing, labeling, timestamps), LLM prompt builder, WAV writer header sanity, SettingsStore defaults.
- Build verification: `swift build -c release`, app bundle assembly, `codesign` ad-hoc, launch smoke test.
- Audio/hotkey/TCC paths require the user's first-run permission grants (documented in README) — cannot be exercised headlessly.

### Distribution / setup

- `scripts/build_app.sh` — release build → `build/JustSayIt.app` (Info.plist with usage strings, LSUIElement) → ad-hoc codesign → optional install to `~/Applications`.
- `scripts/setup_llm.sh` — `brew install llama.cpp` (if missing) + download Qwen3-4B-Instruct-2507-Q4_K_M.gguf from Hugging Face to `~/Library/Application Support/JustSayIt/Models`.
- Whisper model auto-downloads on first launch via WhisperKit (~632 MB).

## Out of scope (v1)

Live streaming transcription during meetings (transcript is produced at stop), speaker diarization beyond Me/Them, push-to-talk hold mode, App Store distribution, localizable UI.
