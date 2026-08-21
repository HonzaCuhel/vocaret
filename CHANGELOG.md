# Changelog

Versioning: [SemVer](https://semver.org/). While at 0.x, minor versions may
change behaviour and defaults.

## [Unreleased] — 0.3.0

### Added
- Appearance (Follow System / Light / Dark) in the menu and Settings.
- Czech user interface (Settings → Interface language; ~150 strings), applied
  live; auto-detect language checklist (12 languages).
- Optional speech engine: NVIDIA Parakeet TDT 0.6B v3 via FluidAudio
  (Settings → Speech engine, ~500 MB download). 3–5× faster than Whisper on
  clean speech; Whisper stays the default because Parakeet drifts on short or
  mixed-language utterances.
- Main menu (Edit / Window) so ⌘C/⌘V/⌘A/⌘Z/⌘W/⌘Q work while the window is open.
- Confirmation before clearing history or deleting a transcript.

### Changed
- Uniform title-bar height on every tab (one window-owned toolbar).
- Short dictations (< 3 s) reuse the last detected language — one encoder pass
  instead of three (one-word dictation 2.2 s → 0.8 s).
- AI cleanup feels ~3× faster: the model is warmed when a recording starts, and
  `llama-server` now sleeps (80 MB resident) instead of being killed, waking in
  ~1 s. Launch flags: `-fa on --sleep-idle-seconds`.
- Coach vocabulary metric is a moving-average type/token ratio (MATTR), so it
  no longer falls the more you dictate; sentence statistics no longer break on
  Czech ordinals/abbreviations/decimals.
- Settings writes only the fields you changed (menu-bar toggles are no longer
  reverted while the Settings tab is open).

### Fixed
- Changing the interface language could wedge the app's main thread.
- Shortcut recorder leaked a key monitor (swallowed ⌘/⌥ keys) if you left
  Settings mid-recording; Esc now cancels; Shift-only chords and duplicate
  chords are refused.
- Deleting a transcript with "keep history" off no longer writes the memory-only
  transcripts to disk; an unreadable history file is never overwritten.
- First Automation (Spotify/Music) prompt no longer appears mid-recording.
- Peak-hours chart clipped the 00 and 23 bars; login toggle lied when unbundled;
  `--coach` / `--selftest` no longer kill the running app's llama-server.
- Music paused for a dictation sometimes never resumed: players report their
  playback state with a lag, and the resume was skipped when the state still
  read "playing". Short dictations hit this almost every time.
- Meeting transcripts no longer inherit the previous speaker's language for
  short utterances; the Parakeet engine no longer loads Whisper as well.
- Sentences that start with a number ("5 minut.") or a quote are counted as
  sentences again in the coach's statistics.
- On llama.cpp builds too old for sleep support, the model is freed after a few
  minutes again instead of staying resident for an hour.
- The menu bar re-localises when you change the interface language.

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
