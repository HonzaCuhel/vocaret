# JustSayIt

A free, fully-local speech-to-text menu-bar app for macOS — a personal Wispr Flow / SuperWhisper
replacement. Czech 🇨🇿 + English 🇬🇧, fast (Apple Neural Engine), RAM-friendly, zero cloud.

## Features

- **Dictation anywhere** — press `⌃⌥D`, speak, press `⌃⌥D` again: the transcript is
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

> **Note:** by default the app is ad-hoc signed. After you **rebuild**, macOS treats it as a new
> binary and asks for Microphone / System Audio again and you may need to re-toggle Accessibility.
> To make grants survive rebuilds, sign with your Apple Development identity once:
> `CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/build_app.sh --install`
> (find it with `security find-identity -v -p codesigning`; the first use pops a keychain dialog —
> click **Always Allow**).

## Usage

| Action | Shortcut |
|---|---|
| Start / finish dictation (paste at caret) | `⌃⌥D` |
| Cancel dictation (while recording or transcribing) | `Esc` |
| Start / finish meeting transcription | `⌃⌥M` |

(Why not `⌃⌥Space`? On Macs with more than one keyboard layout — e.g. U.S. + Czech — that is
macOS's own *Select next source in Input menu* shortcut.)

### Languages

*Auto* mode detects the language per utterance, restricted to Czech and English by default
(`autoLanguages`), which stops Whisper from mistaking Czech for Slovak/Polish. Meeting audio is
split at pauses and each utterance gets its own language, so bilingual calls keep both languages
(Whisper itself can only apply one language per 30-second window — mixing languages *within a
single sentence* is still a model limitation).

Meeting transcripts land in `~/Documents/JustSayIt/Meetings/` as Markdown (raw WAVs in
`~/Documents/JustSayIt/Recordings/`, kept or deleted per the menu toggle).

Menu options: language (Auto / Čeština / English), *Clean Dictation with AI* (off by default —
adds a second or two of latency), *Structure Meetings with AI* (on by default), *Keep Meeting
Audio Files*.

> **Tips:** wear headphones during meetings (with speakers, the mic hears the other participants
> too and their words can show up in both tracks), and pause Spotify/Music — everything the Mac
> plays ends up in the "Them" track.

Long meetings: the LLM has a 16k-token context, so transcripts longer than roughly 20 minutes are
structured in slices (summary + action items per slice, then merged); the cleaned transcript is
omitted for those and the raw transcript is always appended. If the LLM is unavailable, the file
says so at the top and the HUD tells you.

## Configuration

Everything lives in `defaults` under `com.jancuhel.justsayit`:

```bash
# Use a smaller/faster Whisper model (default: openai_whisper-large-v3-v20240930_626MB)
defaults write com.jancuhel.justsayit whisperModel openai_whisper-small

# Change the dictation hotkey (Carbon key code + modifier mask;
# ctrl=0x1000 opt=0x800 shift=0x200 cmd=0x100 — values are ORed together).
# Default is D (2) with ctrl+opt (6144). Example: ⌃⌥Space = key 49:
defaults write com.jancuhel.justsayit dictationKeyCode -int 49
defaults write com.jancuhel.justsayit dictationModifiers -int 6144

# Restrict auto language detection (default cs,en; empty array = any language)
defaults write com.jancuhel.justsayit autoLanguages -array cs en de

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
swift test          # unit tests (merger, chunker, LLM slicing, settings, prompts, sanitizer)
swift build         # debug build
.build/debug/JustSayIt --transcribe audio.wav [--language auto|cs|en]   # headless transcription

# Runtime self-tests exercising the real capture / LLM / paste paths (synthesized speech via `say`;
# they trigger the normal permission prompts). Run through the bundle so TCC attributes correctly:
open -W -a ~/Applications/JustSayIt.app --args --selftest all 8 --out /tmp/selftest.log
# modes: mic | tap | llm | meeting | keys | all
```

Design and plan docs: `docs/superpowers/`.

## Troubleshooting

- **Hotkey does nothing** — another app owns `⌃⌥D`; change it (see Configuration) or free it.
- **Text lands in clipboard but doesn't paste** — grant Accessibility (see Permissions), or
  re-grant after a rebuild.
- **"llama-server not found"** — run `scripts/setup_llm.sh`; cleanup features are optional and
  the app works fine without them (raw transcripts are delivered unchanged).
- **Meeting has no "Them" lines** — check System Settings → Privacy & Security → Screen & System
  Audio Recording → System Audio Recording lists JustSayIt (the saved file and HUD warn when the
  system track was silent the whole time).
- **A meeting was recording when the app quit** — the WAVs in `~/Documents/JustSayIt/Recordings/`
  are finalized on quit; transcribe them with `JustSayIt --transcribe <file>`.
- Logs: `log stream --predicate 'subsystem == "com.jancuhel.justsayit"' --level info`
