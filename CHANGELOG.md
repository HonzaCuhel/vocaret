# Changelog

Versioning: [SemVer](https://semver.org/). While at 0.x, minor versions may
change behaviour and defaults.

## [0.1.0] — 2026-08-17

First public release. Previously developed as "JustSayIt".

### Features
- Hold-to-talk dictation (`⌃⌥D`) inserted at the caret via the Accessibility
  API, with a clipboard + ⌘V fallback. A short tap toggles instead.
- Per-utterance language detection (Czech + English by default), so bilingual
  speech is not forced into a single language per 30-second window.
- Meeting transcription (`⌃⌥M`): microphone plus system audio via a Core Audio
  process tap, merged into a speaker-labelled Markdown transcript.
- Optional local LLM cleanup and meeting structuring via `llama-server`, spawned
  on demand and shut down after 120 s idle. Long transcripts are sliced to fit
  the context window.
- Dictation history — every transcript is recorded before insertion is
  attempted, and is retrievable from the menu bar.

### Notes for this release
- Raw meeting audio is **deleted** after transcription by default; opt in with
  *Keep Meeting Audio Files*.
- A one-time consent notice is shown before the first meeting recording.
- Not notarized: build from source (see README).
