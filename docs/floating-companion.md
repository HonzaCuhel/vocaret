# Floating companion

Vocaret's panel now offers Dictate, Chat and Meeting, with a translucent native
material card, retained conversation, and a microphone-reactive projected 3D
particle sphere. It respects Reduce Motion and Reduce Transparency. The menu-bar
item **Show floating panel** reopens it. The minus button hides it without stopping
capture; Stop finishes capture and X cancels it. Mode changes are locked during
capture/processing. Dictate inserts at the caret; Chat dictation fills the message
composer for review and sending. Meeting uses the existing local dual-track live
transcription and saved-meeting library.

## Agents and memory

Install and sign into `codex` or `claude` in Terminal first. Supported executable
locations are `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`. Select the
agent in Chat. The integration invokes the CLI directly with file-backed stdin,
not shell interpolation. It has cancellation, a 180-second timeout, bounded
output, ephemeral sessions and no configuration/hook installation. Codex uses
read-only sandboxing and ignores user configuration; Claude has no tools, hooks
or MCP servers. CLI upgrades may change flags; failures are shown in the panel.

The **Remember** button under Dictate opens the last completed dictation as a
proposed addition to the existing memory. Edit it, then click **Save memory** to
apply it, or Cancel to discard it. This action runs entirely locally and makes
no agent request. Ordinary dictation only updates the available last text.

The brain icon edits Vocaret's memory document. To ask an agent for an edit, type
an instruction in Chat, then choose **Propose memory edit**. Review the returned
complete document and click **Save memory**. Existing memory is sent with future
messages. This is shared Vocaret context for either CLI, not access to private
Codex or Claude memory databases and not control of an already-running task.

## Playback

Enable **Pause Music While Recording** in the menu. Spotify and Music pause and
resume through their native playback state. YouTube is supported in Chrome,
Safari, Edge and Brave, including background tabs. Grant macOS Automation access
and enable **Allow JavaScript from Apple Events** in the browser's Develop menu
(or View > Developer). Permission failures are logged and never block recording.
Only YouTube videos actually paused by this recording are eligible to resume;
source changes, manual seeking, closed tabs and navigation cancel eligibility.
Autoplay policy can still refuse a resume. Firefox is not supported.

## Reference analysis and original implementation

Reference: https://github.com/aveekpatra/speek (inspected 2026-09-09).
Speek uses a compact non-activating recorder, edge anchoring and agent reply
panels; its README describes lifecycle hooks and a named-pipe agent protocol.
The inspected source includes MiniRecorderPanel, AgentEventListener and
MediaController. Its deployment target is macOS 26 and its license is GPL-3.0.

Vocaret implements the interaction ideas independently: AppKit/SwiftUI materials
on its existing macOS target, a mathematical particle animation, explicit
stateless CLI requests carrying bounded history, and reviewed memory documents.
No Speek source code, assets, branding, hook installer or IPC implementation was
copied. The supplied screenshot informed the stacked floating-card composition.

Reference commit: `5bbc049b4a7cbff90f5fee24a63b8cd7e8989bf8`.

## Verification commands

- `swift test`: local regression suite; live account tests are opt-in.
- `VOCARET_AGENT_SMOKE=1 swift test --filter CompanionTests.testInstalledAgentConversationAndMemoryProposal`:
  sends fictional context to each installed CLI and checks follow-up recall and a
  memory proposal. Uses the signed-in account's quota.
- `Vocaret --render-companion build/verification/companion`: renders four native
  views with fictional Czech messages.
- `Vocaret --selftest hud --out build/verification/companion/hud-runtime.log`:
  checks recorder state transitions and native rendering.

Live check on 2026-09-09: Codex conversation recall and memory proposal passed.
Claude returned a session quota limit, so its successful cloud reply is not yet
verified. Chrome Apple Events did not complete the permission request in the
bounded probe; real YouTube playback remains unverified on this Mac. Spotify was
not running. JavaScript tests cover pause/resume ownership, repeated resume,
initially paused video, manual seeking, changed source and non-YouTube hosts.

Final local gates: 172 XCTest cases, 2 expected skips, no failures. Release build,
strict code-sign verification and the packaged HUD runtime self-test passed.
The local bundle uses the project's supported ad-hoc signing mode; the installed
copy was not replaced. Developer-certificate signing did not finish unattended.
A packaged meeting-stream run reached model preparation but Core ML reported
no disk space while creating MPSGraph caches; that run was terminated and does
not establish successful meeting inference. Only the regenerable debug
ModuleCache was removed to make room for packaging. Real microphone/system
capture, playback and successful Claude responses still require runtime checks
with available disk space, granted permissions and an account below its quota.

## Installer packaging

`./scripts/build_dmg.sh` builds the app and a compressed, verified DMG with an
Applications shortcut. `--skip-build` packages an already verified app;
`--version 0.2.0-beta.1` labels a prerelease. A matching SHA-256 file is generated.
The script preserves existing output files and validates the application signature.
The v0.2.0-beta.1 artifact is arm64-only, ad-hoc signed and not notarized.
