# Repository Guidelines

## Project Structure & Module Organization

Vocaret is a Swift Package for a macOS 14.4+ menu-bar app. Application logic and AppKit UI live in `Sources/VocaretCore/`; keep `Sources/Vocaret/main.swift` as the thin executable entry point. Unit tests belong in `Tests/VocaretTests/` and should mirror the production type they cover. `Resources/` contains bundle metadata and the generated app icon, while `assets/` holds README artwork. Use `scripts/` for repeatable build/setup utilities. The notes under `docs/` are historical; when they conflict, follow the source and top-level `README.md`.

## Build, Test, and Development Commands

- `swift build` — compile a debug build with SwiftPM.
- `swift test` — run the XCTest suite; it does not require speech or LLM models.
- `swift build -c release` — compile the optimized executable.
- `./scripts/build_app.sh` — create `build/Vocaret.app`; add `--install` to replace and launch `~/Applications/Vocaret.app`.
- `.build/debug/Vocaret --transcribe audio.wav --language auto` — exercise file transcription from the CLI.
- `open -W -a ~/Applications/Vocaret.app --args --selftest all 8 --out /tmp/selftest.log` — run permission-dependent runtime checks after installing the app.

## Coding Style & Naming Conventions

Follow standard Swift API design: four-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and descriptive enum cases. Name files after their primary type (for example, `TranscriptMerger.swift`). Keep UI/state orchestration on the main actor where required, and use `Sendable` for values crossing concurrency boundaries. No formatter or linter is configured, so match nearby code and keep `swift build` warning-free.

## Testing Guidelines

Tests use XCTest. Name suites `<Type>Tests` and methods `test<ExpectedBehavior>()`, such as `testCoalescesSameSpeakerWithinGap`. Add focused regression tests for bug fixes, including empty, boundary, and bilingual-input cases where relevant. Run `swift test` before every pull request; use runtime self-tests for changes involving audio capture, Accessibility, pasting, meetings, or the local LLM. No numeric coverage threshold is defined.

## Commit & Pull Request Guidelines

Recent history favors concise, imperative subjects prefixed with `feat:`, `fix:`, `perf:`, or `docs:`; combined scopes such as `fix+perf:` are also used. Keep commits focused. Pull requests should explain user-visible behavior, list verification performed, link relevant issues, and include screenshots for UI changes. Call out new permissions, model downloads, defaults, or privacy implications.

## Security & Configuration Tips

Never commit models, recordings, transcripts, credentials, or machine-specific paths. Preserve the signing safeguards in `scripts/build_app.sh`; do not weaken the designated requirement to retain macOS permissions. Keep dependencies intentionally constrained in `Package.swift`, and document any network access or data-retention change in `PRIVACY.md`.
