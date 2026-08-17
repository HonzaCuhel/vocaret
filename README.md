# Utter

**Local speech-to-text for macOS.** Hold a key, speak, let go — your words appear
where your cursor is. Czech and English, mixed freely. Nothing is sent anywhere.

> **Status: v0.1.0, early.** Built by one person, working well daily on one Mac.
> Expect rough edges. There is no settings window yet — configuration is via
> `defaults write`. Please read [what this is not](#what-this-is-not) before
> installing.

## What it does

- **Dictation anywhere** — hold `⌃⌥D`, speak, release. The text is inserted at
  your caret in any app. A quick tap toggles recording instead, if you prefer.
- **Bilingual by design** — Czech and English are detected *per utterance*, so a
  meeting that switches languages mid-conversation transcribes correctly. (Most
  tools apply one language per 30-second window and lose one of them.)
- **Meeting transcription** — `⌃⌥M` records your microphone *and* your Mac's
  audio output, producing a speaker-labelled transcript (`Me` / `Them`). No
  virtual audio driver needed.
- **Optional local cleanup** — a small language model removes filler words and
  structures meeting notes into a summary and action items.

Everything runs on your Mac: Whisper via Core ML on the Neural Engine, and
llama.cpp on localhost. See [PRIVACY.md](PRIVACY.md) for the precise details,
including the two one-time model downloads and one caveat about `~/Documents`.

## Requirements

- **Apple Silicon** Mac (M1 or newer) — Intel is not supported
- **macOS 14.4+** (the meeting feature needs the Core Audio process tap API)
- Xcode or the Command Line Tools, to build
- ~700 MB disk for the speech model; ~2.4 GB more if you want the LLM cleanup

## Install

Utter is distributed as source. Building it yourself takes about a minute and
means macOS trusts the app you built — no Gatekeeper warnings, no unsigned
download to talk yourself into.

```bash
git clone https://github.com/<your-account>/utter.git
cd utter
./scripts/build_app.sh --install
```

That builds `~/Applications/Utter.app` and launches it. Look for the microphone
icon in your menu bar — the app has no window and no Dock icon.

Optional, for the AI cleanup features:

```bash
./scripts/setup_llm.sh      # installs llama.cpp via Homebrew + downloads a 2.4 GB model
```

Without it, Utter still transcribes perfectly; only the cleanup features are
skipped, and it tells you so.

### First run

The speech model (~626 MB) downloads on first launch. The menu bar shows the
progress; until it finishes, dictation will wait.

macOS will ask for permissions as you first use each feature:

| Permission | When | Needed for |
|---|---|---|
| **Microphone** | first dictation | recording your voice |
| **Accessibility** | first insertion | typing the text at your cursor |
| **System Audio Recording** | first meeting | hearing other participants |

If Accessibility is missing, the menu-bar icon shows a warning badge and the
menu offers a one-click fix. Without it, transcripts go to your clipboard
instead of being typed.

## Usage

| Action | Shortcut |
|---|---|
| Dictate (hold, speak, release) | `⌃⌥D` |
| Dictate (tap to start, tap to stop) | `⌃⌥D` short tap |
| Cancel | `Esc` |
| Meeting transcription start/stop | `⌃⌥M` |

Everything else is in the menu-bar menu: language (Auto / Čeština / English),
push-to-talk on/off, the recording overlay, AI cleanup toggles, **Copy Last
Dictation**, and **Open Dictation History** — so a transcript is never lost even
if insertion fails.

`⌃⌥D` rather than `⌃⌥Space` because on Macs with more than one keyboard layout,
`⌃⌥Space` is macOS's own input-source switcher.

## Before you record a meeting

Meeting mode records **everyone on the call**, not just you.

In many countries you must tell the other participants first. In some — Germany
(§201 StGB) among them — recording a private conversation without consent is a
criminal offence, and within the EU such a recording is personal data under the
GDPR. Utter shows a one-time warning and deletes the raw audio after
transcribing by default, but **the legal responsibility is yours**.

Practical advice: say out loud that you are recording, and wear headphones —
otherwise your microphone picks up the other side too and it appears in both
tracks.

## Configuration

There is no settings window yet. Everything lives in `defaults`:

```bash
# Smaller/faster speech model (default: openai_whisper-large-v3-v20240930_626MB)
defaults write com.jancuhel.utter whisperModel openai_whisper-small

# Change the dictation hotkey (Carbon key code + modifier mask:
# ctrl 0x1000, opt 0x800, shift 0x200, cmd 0x100, ORed together).
# Default is D (2) with ctrl+opt (6144).
defaults write com.jancuhel.utter dictationKeyCode -int 2
defaults write com.jancuhel.utter dictationModifiers -int 6144

# Languages considered in Auto mode (default cs,en). If you speak something
# else, set it here or Auto will force your speech into Czech or English.
defaults write com.jancuhel.utter autoLanguages -array de en

# Keep raw meeting audio instead of deleting it after transcription
defaults write com.jancuhel.utter keepRecordings -bool true

# Stop logging every dictation to disk
defaults write com.jancuhel.utter keepDictationHistory -bool false

# Free the model's RAM after 10 idle minutes instead of keeping it warm
defaults write com.jancuhel.utter keepModelLoaded -bool false
```

Restart Utter after changing hotkeys.

## What this is not

- **Not notarized.** There is no signed download, because notarization needs a
  paid Apple Developer account. You build it yourself instead. If you would
  rather not build software you have not read, that is a reasonable position —
  do not install this.
- **Not a polished product.** No onboarding, no settings UI, no auto-update, no
  hotkey picker. Compare with [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper),
  [VoiceInk](https://github.com/Beingpax/VoiceInk) or Wispr Flow if you want that.
- **Not supported.** This is a personal project shared in case it is useful.
  Issues are welcome; timely answers are not promised.
- **Not tested broadly.** It has run on exactly one Mac, macOS 26, M3 Pro.
- **Not for languages other than Czech and English** without changing
  `autoLanguages` — Auto mode will otherwise confidently transcribe nonsense.

## Performance

Whisper `large-v3-turbo` (626 MB, quantized) runs on the Neural Engine — a short
dictation transcribes in well under a second once warm. Resident memory with the
model loaded is roughly 700–900 MB, most of it memory-mapped weights macOS can
reclaim. The cleanup LLM costs **zero RAM when idle**: `llama-server` is spawned
per job and killed after 120 seconds (~2.8 GB while it runs).

Lightest setup: `whisperModel openai_whisper-small` + `keepModelLoaded false` +
AI cleanup off.

## Uninstall

```bash
rm -rf ~/Applications/Utter.app
rm -rf ~/Library/Application\ Support/Utter    # models, dictation history
rm -rf ~/Documents/Utter                        # meeting transcripts and audio
defaults delete com.jancuhel.utter
```

Then remove Utter from System Settings → Privacy & Security → Accessibility,
Microphone and System Audio Recording.

## Development

```bash
swift test                                  # 27 unit tests, no network or models needed
swift build
.build/debug/Utter --transcribe audio.wav [--language auto|cs|en]

# Runtime self-tests that exercise real capture / LLM / paste paths.
# They synthesize speech with `say` and trigger the normal permission prompts.
open -W -a ~/Applications/Utter.app --args --selftest all 8 --out /tmp/selftest.log
# modes: mic | tap | llm | meeting | keys | all
```

**A note on rebuilds:** an ad-hoc signature changes identity on every build, so
macOS drops your Accessibility grant each time. To keep it, sign with your own
Apple Development certificate (free with an Apple ID, via Xcode):

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/build_app.sh --install
```

Do **not** work around this by overriding the designated requirement to match on
bundle identifier — that lets any app claiming the identifier inherit your
granted permissions. See the comment in `scripts/build_app.sh`.

Architecture and design notes: [docs/](docs/).

## Troubleshooting

- **Hotkey does nothing** — is the app running? It is menu-bar only. Enable
  *Start at Login*. Otherwise another app may own `⌃⌥D`; change it above.
- **Text lands on the clipboard instead of being typed** — grant Accessibility
  (menu → *⚠︎ Accessibility not granted*). After an ad-hoc rebuild you must
  toggle it off and on again.
- **`llama-server not found`** — run `scripts/setup_llm.sh`, or ignore it; the
  cleanup features are optional.
- **Meeting has no `Them` lines** — check System Settings → Privacy & Security →
  Screen & System Audio Recording. The saved transcript warns you when the
  system track was silent throughout.
- **Logs** — `log stream --predicate 'subsystem == "com.jancuhel.utter"' --level info`

## License

[Apache-2.0](LICENSE). Third-party components and model licenses:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
