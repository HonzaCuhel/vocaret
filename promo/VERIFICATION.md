# Companion promo verification

## Scope

36-second silent illustrative product film. Synthetic text throughout, not a recording of live account interactions. No claims about successful Claude responses, media control, or widget auto-hide. New original app icon copied from `docs/assets/icon.png`.

## Toolchain

HyperFrames remains pinned at **0.8.27**. Upgrade probe reported **0.8.33**, but its Sharp/libvips native dependency was rejected by macOS library loading policy. No signing or machine security settings were changed. The original pin runs using a fresh writable npm cache.

## Checks

Full `npm run check` (lint, runtime, layout, motion, contrast): initial pass had 0 errors, 0 layout issues over 9 samples, 0 motion findings, 63/63 contrast checks passing. One reviewed warning flags the intentional reuse of the app icon in the persistent header and closing scene; both nodes are visually correct.

Visual checks: scene snapshots at 3, 10.5, 18, 23.5, 25.5, 29, 35 seconds. Memory draft and saved states distinct, no overlap/clipping, end card legible. Improved particle billboarding after first visual review, so sphere points remain visible through its rotation. Final export verification recorded below after render.

## Final output

- Final full `npm run check`: **passed**, 0 lint errors (1 reviewed duplicate-icon warning), 0 runtime errors/warnings, 0 layout issues / 9 samples, 0 motion errors/warnings, **63/63 WCAG AA text checks**.
- `npm run render -- --quality high --fps 30 --workers 2 --output ../docs/assets/vocaret-companion-promo.mp4`: **passed** on HyperFrames 0.8.27.
- ffprobe: **H.264, 1920×1080, 30 fps, 1,080 frames, exactly 36.000s, 6,534,109 bytes**. Silent by design, no audio stream.
- Full FFmpeg decode to null: **exit 0, no errors**.
- MP4 samples inspected at 3, 10.5, 18, 23.5, 25.5, 29 and 35 seconds. All six scenes present and readable; draft/save states distinct; closing frame holds. Contact sheet: `.verification/render-contact.jpg` (local, ignored).
- Poster extracted from the **final MP4 at 3 seconds**: `../docs/assets/vocaret-companion-poster.jpg` (1920×1080).
- No root README, website HTML/CSS/JS, Swift files or existing shared icon modified by this video task. No commit/push performed; parent handles integration and publication.
