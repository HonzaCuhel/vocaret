# JustSayIt

A free, fully-local speech-to-text menu-bar app for macOS — a personal Wispr Flow / SuperWhisper
replacement. Czech 🇨🇿 + English 🇬🇧, fast (Apple Neural Engine), RAM-friendly, zero cloud.

## Features

- **Dictation anywhere** — press `⌃⌥Space`, speak, press `⌃⌥Space` again: the transcript is
  pasted at the text caret of whatever app you're in. `Esc` cancels a recording.
- **Meeting transcription** — press `⌃⌥M` during any call (Google Meet, Zoom, anything that
  plays audio). JustSayIt records both your microphone (**Me**) and everything the Mac plays
  (**Them**), then produces a labeled transcript with timestamps.
- **Local AI cleanup** — a small local LLM (Qwen3-4B via llama.cpp) fixes punctuation, strips
  filler words, and structures meeting notes into Summary / Action items / Cleaned transcript.
- **100 % local** — Whisper runs via WhisperKit on the Neural Engine; the LLM runs via
  llama-server on localhost. Nothing ever leaves the Mac.

## Requirements

- Apple Silicon Mac, macOS 14.4+ (built and tested on macOS 26)
- Xcode (or Command Line Tools) to build
- Homebrew (for llama.cpp, optional — only needed for the AI-cleanup features)
- Disk: ~630 MB Whisper model + ~2.4 GB LLM model (optional)

## Setup

```bash
# 1. Build and install the app to ~/Applications
scripts/build_app.sh --install

# 2. (Optional, for AI cleanup) install llama.cpp + download the LLM model (~2.4 GB)
scripts/setup_llm.sh

# 3. Launch
open ~/Applications/JustSayIt.app
```

On first launch the Whisper model (~630 MB) downloads automatically; the HUD shows progress.
After that everything is offline.

### Permissions (one-time)

| Permission | When macOS asks | Needed for |
|---|---|---|
| **Microphone** | first recording | dictation + your side of meetings |
| **Accessibility** | first transcript insertion | auto-pasting text at the caret (until granted, the transcript is put on the clipboard and you press ⌘V yourself) |
| **System Audio Recording** | first meeting transcription | hearing the other meeting participants |

Check them anytime via menu-bar icon → *Check Permissions…*.

> **Note:** the app is ad-hoc signed. After you **rebuild**, macOS treats it as a new binary and
> you may need to re-grant Accessibility (toggle JustSayIt off and on in
> System Settings → Privacy & Security → Accessibility).

## Usage

| Action | Shortcut |
|---|---|
| Start / finish dictation (paste at caret) | `⌃⌥Space` |
| Cancel dictation while recording | `Esc` |
| Start / finish meeting transcription | `⌃⌥M` |

Meeting transcripts land in `~/Documents/JustSayIt/Meetings/` as Markdown (raw WAVs in
`~/Documents/JustSayIt/Recordings/`, kept or deleted per the menu toggle).

Menu options: language (Auto / Čeština / English), *Clean Dictation with AI* (off by default —
adds a second or two of latency), *Structure Meetings with AI* (on by default), *Keep Meeting
Audio Files*.

> **Tip:** wear headphones during meetings. With speakers, the mic hears the other participants
> too and their words can show up in both tracks.

## Configuration

Everything lives in `defaults` under `com.jancuhel.justsayit`:

```bash
# Use a smaller/faster Whisper model (default: openai_whisper-large-v3-v20240930_626MB)
defaults write com.jancuhel.justsayit whisperModel openai_whisper-small

# Change the dictation hotkey (Carbon key code + modifier mask;
# ctrl=0x1000 opt=0x800 shift=0x200 cmd=0x100 — values are ORed together)
defaults write com.jancuhel.justsayit dictationKeyCode -int 49
defaults write com.jancuhel.justsayit dictationModifiers -int 6144

# Unload Whisper after 10 idle minutes instead of keeping it warm
defaults write com.jancuhel.justsayit keepModelLoaded -bool false
```

Restart the app after changing hotkeys.

## RAM / performance notes

- Whisper `large-v3-turbo` (626 MB quantized) runs on the Neural Engine; a 10 s dictation
  transcribes in well under a second once warm. Resident memory with the model loaded is
  roughly 700–900 MB, most of it memory-mapped weights macOS can reclaim.
- The LLM costs **zero RAM when idle** — `llama-server` is spawned per job and killed after
  120 s of inactivity (~2.8 GB while it runs).
- Lowest-footprint setup: `whisperModel openai_whisper-small` + `keepModelLoaded false` +
  leave AI cleanup off.

## Development

```bash
swift test          # unit tests (merger, settings, prompts, sanitizer)
swift build         # debug build
.build/debug/JustSayIt --transcribe path/to/audio.wav   # headless transcription check
```

Design and plan docs: `docs/superpowers/`.

## Troubleshooting

- **Hotkey does nothing** — another app owns `⌃⌥Space`; change it (see Configuration) or free it.
- **Text lands in clipboard but doesn't paste** — grant Accessibility (see Permissions), or
  re-grant after a rebuild.
- **"llama-server not found"** — run `scripts/setup_llm.sh`; cleanup features are optional and
  the app works fine without them (raw transcripts are delivered unchanged).
- **Meeting has no "Them" lines** — check System Settings → Privacy & Security → Screen & System
  Audio Recording → System Audio Recording lists JustSayIt.
- Logs: `log stream --predicate 'subsystem == "com.jancuhel.justsayit"' --level info`
