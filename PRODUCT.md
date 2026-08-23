# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Vocaret is for Apple Silicon Mac users who want fast, keyboard-driven dictation in Czech, English, or both without leaving the app where they are working. This audience and its workflow are inferred from the shipped shortcuts, README, and current implementation.

## Product Purpose

Hold a shortcut, speak, and release to insert text at the current cursor. Success means the speaker sees useful live feedback, gets a reliable transcript, and can understand when audio leaves the Mac.

## Positioning

Vocaret combines local-first Whisper or Parakeet transcription, optional Soniox live words, bilingual utterance handling, and a complete local fallback recording in one macOS menu-bar app.

## Operating Context

The primary workflow happens in other Mac apps through `⌃⌥D`; Vocaret stays in the menu bar and uses a non-activating floating recorder panel. Settings, history, meetings, and speaking-coach tools live in the optional main window.

## Capabilities and Constraints

- macOS 14.4+ and Apple Silicon are required.
- Local engines keep audio on the Mac; Soniox is explicit opt-in and uses a user-supplied regional project key.
- The project is distributed as source and is not notarized or auto-updating.
- Microphone and Accessibility permissions are required for the core workflow.

## Brand Commitments

Keep the name Vocaret, the existing purple microphone icon in `assets/icon.png`, direct product language, and a calm native-Mac character. The requested website may establish a fresher visual system without inventing commercial claims.

## Evidence on Hand

The working Swift application, its self-tests, README, privacy policy, icon, and repository history are the available proof. There are no testimonials, customer logos, or broad-device support claims to publish.

## Product Principles

- Make keyboard dictation feel immediate.
- Keep local processing the default and cloud processing explicit.
- Show live state without stealing focus or adding visual noise.
- Describe limitations and permissions honestly.

## Accessibility & Inclusion

Respect Reduce Motion, support light and dark macOS appearances, preserve legible contrast, expose meaningful accessibility labels, and keep the website usable by keyboard and on small screens.
