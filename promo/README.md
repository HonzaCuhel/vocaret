# Vocaret launch film

A reproducible 36-second, 1920×1080, 30 fps HyperFrames composition for the product website. Six scenes share one paused GSAP timeline. The film is intentionally silent; every message is on screen.

## Render

Node.js 22+, FFmpeg, and a supported Chromium browser are required. The CLI is pinned in `package.json`; GSAP and the licensed display font are local assets, so the composition itself makes no external requests.

```sh
npm run check
npx --yes hyperframes@0.8.27 snapshot --at 3.8,11.8,17.8,23.8,30,35.5
npm run render -- --quality high --fps 30 --workers 2 --output ../docs/assets/vocaret-meetings-promo.mp4
ffmpeg -ss 11.8 -i ../docs/assets/vocaret-meetings-promo.mp4 -frames:v 1 -q:v 2 ../docs/assets/vocaret-meetings-poster.jpg
```

The rendered video and poster live in `../docs/assets/`. Preview snapshots and transient renderer caches are ignored. If the machine's npm cache is not writable, set `npm_config_cache` to a fresh writable temporary directory; do not delete or loosen permissions on another cache.

## Scenes and evidence

1. 0–5s: Keep the conversation; dictation + meetings.
2. 5–13s: Illustrative Me/Them transcript arriving during a call.
3. 13–19s: Actual native meeting panel with synthetic demo text.
4. 19–25s: Model prepares, passages process during recording, stopping finishes remaining passages.
5. 25–31s: Ctrl+Option+D dictation; local meeting processing and explicit cloud dictation opt-in.
6. 31–36s: Vocaret/source CTA and Apple Silicon/macOS requirements.

No latency number or completed real-call benchmark is claimed. The native screenshot is supplied by the app's UI verification fixture. The animated transcript is a clearly labeled conceptual demonstration and does not claim word-by-word streaming for the meeting engine.

## Asset provenance

- `assets/icon.png`: repository's canonical Vocaret icon.
- `assets/meetings-live-dark.png`: repository UI verification screenshot, synthetic text.
- `assets/fonts/barlow-condensed-700.ttf`: the existing site font, SIL Open Font License in the same directory.
- `assets/vendor/gsap.min.js`: GSAP 3.14.2 distribution, license URL included in its header.
- `compositions/components/line-by-line-slide.html`: HyperFrames registry primitive consulted for the opening line reveals; opening motion adapts its paused `fromTo` recipe.

No paid generation services, stock media, music, or narration are used.
