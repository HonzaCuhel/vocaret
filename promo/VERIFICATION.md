# Verification — 2026-09-04

- HyperFrames 0.8.27: runtime and layout checks passed at 13 timeline samples.
- All 42 sampled contrast checks passed.
- Motion sidecar checks passed across 300 samples: opening appearance, ordered transcript entries, native screenshot and CTA remain in frame.
- Opening keyframe trajectory was inspected; 19 snapshots covered six scenes, each cut, and the final hold. No clipped copy or unexpected final black frame was observed.
- One reviewed lint warning remains: the same canonical icon image appears in both the header and closing scene. Each is shown in a separate timed scene; the rendered frames confirm correct placement.
- The native screenshot contains synthetic fixture text. The illustrative meeting animation is labeled, and no latency or real-call benchmark claim is made.

This verifies the promo artifact. Application runtime/test evidence is maintained separately under the repository's build verification directory.

## Final MP4

`docs/assets/vocaret-meetings-promo.mp4` (relative to repository root):

- 36.000 seconds; 1,080 frames at 30 fps.
- H.264, yuv420p, 1920×1080; 3,611,822 bytes.
- No audio stream, intentionally silent.
- `moov` atom precedes `mdat` for progressive web playback.
- Full FFmpeg decode completed with no errors.
- A six-scene contact sheet extracted from the encoded MP4 was inspected, plus direct seeks at the meeting and processing scene ends. The third transcript line and Finish stage are present. Contact-sheet extraction uses `setpts=N/FRAME_RATE/TB` after `select` to avoid timestamp-related tile omissions.
- Poster is extracted from the verified encoded frame at 11.8s.

Rendered contact sheet: `build/verification/vocaret-promo-contact-sheet.jpg` (repository root; generated, not part of composition source).
