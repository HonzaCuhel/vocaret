# Privacy

Vocaret is local by default and offers an explicit, optional Soniox live mode.
This document states exactly what leaves the Mac in each mode.

## What leaves your Mac

With **Whisper or Parakeet selected**, microphone audio and transcripts stay on
the Mac. Speech recognition uses Core ML and optional cleanup uses
`llama-server` on `127.0.0.1`.

With **Soniox selected**, Vocaret opens a WebSocket to the chosen Soniox EU or
US endpoint while dictation is active. The API key must belong to a project in
that same region; Soniox notes that regional access may require contacting its
support. Vocaret sends 16 kHz microphone audio plus
language hints and your vocabulary terms, and receives partial/final transcript
tokens. The complete audio is also retained in memory for local fallback; a
cloud failure does not upload it elsewhere. Soniox documents no storage for
real-time requests unless storage is explicitly enabled (Vocaret does not enable
it) and separate [EU data residency](https://soniox.com/docs/data-residency).
Review [Soniox security and privacy](https://soniox.com/docs/security-and-privacy)
before opting in.

When a Soniox key is connected, Settings also calls the selected region's
`/v1/usage/summary` endpoint to display the exact month-to-date `stt-rt-v5`
cost, request count, and processed audio duration. That request sends the API
key for authentication but no recording or transcript.

The Soniox API key is supplied by you and stored in the macOS Data Protection
Keychain when the app has a provisioning profile. Local ad-hoc builds use
`~/Library/Application Support/Vocaret/Secrets/soniox.key` instead; its
directory is mode `0700`, the file is mode `0600`, and it is excluded from
backups. The key is never stored in `UserDefaults`, logs, or repository files.
There is no Vocaret analytics, telemetry, crash reporting, account, or operated
server.

**Three possible downloads, all one-time and all of models, never of your data:**

1. On first launch Vocaret downloads the speech-recognition model (~1.6 GB for
   the default Whisper large-v3-turbo) from Hugging Face (`huggingface.co`,
   repository `argmaxinc/whisperkit-coreml`).
2. If you run `scripts/setup_llm.sh`, it downloads a language model (~2.4 GB)
   from Hugging Face and installs `llama.cpp` via Homebrew.
3. Only if you switch Settings → Speech engine to Parakeet: the NVIDIA Parakeet
   TDT 0.6B v3 Core ML model (~500 MB) from Hugging Face (repository
   `FluidInference/parakeet-tdt-0.6b-v3-coreml`).

After local model downloads, Whisper/Parakeet mode works offline. Soniox mode
requires networking and paid Soniox API access.

## What is stored on your Mac, and where

| What | Where | Default |
|---|---|---|
| Dictation history (plain text) | `~/Library/Application Support/Vocaret/dictation-history.md` | Kept — turn off with `keepDictationHistory` |
| Meeting transcripts (Markdown) | `~/Documents/Vocaret/Meetings/` | Kept |
| Raw meeting audio (WAV) | `~/Documents/Vocaret/Recordings/` | **Deleted** after transcription — opt in via *Keep Meeting Audio Files* |
| Models | `~/Library/Application Support/Vocaret/Models/` | Kept |
| Settings | `defaults` domain `com.jancuhel.vocaret` | — |
| Soniox API key (optional) | Data Protection Keychain; protected local file for ad-hoc builds | Kept until removed in Settings |

Two consequences worth knowing:

- **`~/Documents` is synced to iCloud Drive** for anyone who enabled "Desktop &
  Documents Folders" in iCloud settings. If that is you, meeting transcripts
  leave your Mac — not to Vocaret, but to Apple. Turn that off, or move the files.
- These files are **not encrypted** beyond whatever FileVault gives you. They
  are indexed by Spotlight and included in Time Machine backups.

To delete everything Vocaret ever wrote:

```bash
rm -rf ~/Library/Application\ Support/Vocaret ~/Documents/Vocaret
defaults delete com.jancuhel.vocaret
security delete-generic-password -s com.jancuhel.vocaret.api-key -a soniox
```

## Recording other people

Meeting mode records **everyone on the call**, because it captures your Mac's
audio output as well as your microphone.

In many jurisdictions you must inform the other participants; in some (for
example Germany, §201 StGB) recording a private conversation without consent is
a criminal offence, and in the EU the recording is personal data under the GDPR.
Vocaret shows a one-time warning before your first meeting recording, but the
legal responsibility is yours, not the software's.

If you are in the EU and record other people, **you** are the data controller
for those recordings. The author of Vocaret does not receive the data; if you
choose Soniox for dictation, Soniox is the external processor for that audio.

## Permissions Vocaret asks for

- **Microphone** — to record your voice.
- **Accessibility** — to type the transcript where your cursor is. This is a
  powerful permission; the source is public so you can verify how it is used
  (`Sources/VocaretCore/TextInserter.swift`).
- **System Audio Recording** — only for meeting mode, to hear other participants.
- **Automation for Spotify / Music** — only to send *pause* when a recording
  starts and *play* when it ends. Vocaret reads nothing else from these apps.

Vocaret is not sandboxed, because the Core Audio process tap and caret insertion
are not possible inside the App Sandbox.
