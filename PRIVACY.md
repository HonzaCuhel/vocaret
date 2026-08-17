# Privacy

Vocaret is designed so your speech never leaves your Mac. This document states
precisely what that means — including the parts that are not absolute.

## What leaves your Mac

**Your audio and transcripts: never.** Speech recognition runs locally
(WhisperKit / Core ML on the Neural Engine). Text cleanup runs locally
(`llama-server` on `127.0.0.1`). There is no analytics, no telemetry, no crash
reporting, no account, and no server operated by anyone.

**Two downloads, both one-time and both of models, never of your data:**

1. On first launch Vocaret downloads the speech-recognition model (~626 MB) from
   Hugging Face (`huggingface.co`, repository `argmaxinc/whisperkit-coreml`).
2. If you run `scripts/setup_llm.sh`, it downloads a language model (~2.4 GB)
   from Hugging Face and installs `llama.cpp` via Homebrew.

After that Vocaret works fully offline. You can verify this with Little Snitch,
LuLu, or by disabling networking.

## What is stored on your Mac, and where

| What | Where | Default |
|---|---|---|
| Dictation history (plain text) | `~/Library/Application Support/Vocaret/dictation-history.md` | Kept — turn off with `keepDictationHistory` |
| Meeting transcripts (Markdown) | `~/Documents/Vocaret/Meetings/` | Kept |
| Raw meeting audio (WAV) | `~/Documents/Vocaret/Recordings/` | **Deleted** after transcription — opt in via *Keep Meeting Audio Files* |
| Models | `~/Library/Application Support/Vocaret/Models/` | Kept |
| Settings | `defaults` domain `com.jancuhel.vocaret` | — |

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
for those recordings. The author of Vocaret is not — no data ever reaches them.

## Permissions Vocaret asks for

- **Microphone** — to record your voice.
- **Accessibility** — to type the transcript where your cursor is. This is a
  powerful permission; the source is public so you can verify how it is used
  (`Sources/VocaretCore/TextInserter.swift`).
- **System Audio Recording** — only for meeting mode, to hear other participants.

Vocaret is not sandboxed, because the Core Audio process tap and caret insertion
are not possible inside the App Sandbox.
