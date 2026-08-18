# Changelog

Versioning: [SemVer](https://semver.org/). While at 0.x, minor versions may
change behaviour and defaults.

## [0.2.0] — 2026-08-18

### Added
- Main window (menu bar → *Open Vocaret*, ⌘O): Dashboard, History, Meetings,
  Coach, Settings. Opens automatically on first launch.
- Dashboard: words today / this week / total, speaking pace, time saved vs
  typing at 40 wpm, streak, last-14-days and peak-hours charts, recent transcripts.
- Speaking coach: filler rate, sentence length, vocabulary richness, pace, plus a
  local-LLM note and a curated reading list matched to the measurements.
- History with search, detail, copy, delete; Meetings viewer with copy/reveal.
- Settings UI with a shortcut recorder, model picker, vocabulary editor, toggles.
- Recording overlay now animates with the live microphone level and shows a timer.
- Music (Spotify, Apple Music) is paused while recording and resumed after —
  only if it was playing, only what Vocaret paused. Toggle in Settings / menu.
- Dictation records carry timing (recording length, transcription latency) in
  `dictation-history.jsonl`; the old Markdown history is imported once.

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
