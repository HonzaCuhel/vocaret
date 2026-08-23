---
name: Vocaret
description: Local-first dictation presented as a live caption control room.
colors:
  ink: "#02030d"
  deep: "#01071a"
  deep-soft: "#07163d"
  paper: "#efedee"
  paper-muted: "#b9bfd0"
  violet: "#7344f3"
  violet-bright: "#8d63ff"
  live: "#f62024"
  broadcast-line: "rgba(141, 176, 255, 0.27)"
  broadcast-line-strong: "rgba(141, 176, 255, 0.5)"
  white: "#ffffff"
  light-ink: "#10131b"
  code-surface: "#11141b"
  light-divider: "#b5bac5"
typography:
  display:
    fontFamily: '"Barlow Condensed", "Arial Narrow", sans-serif'
    fontSize: "clamp(4.5rem, 10vw, 6rem)"
    fontWeight: 700
    lineHeight: 0.76
    letterSpacing: "-0.025em"
  headline:
    fontFamily: '"Barlow Condensed", "Arial Narrow", sans-serif'
    fontSize: "clamp(3rem, 6vw, 5.6rem)"
    fontWeight: 600
    lineHeight: 0.92
    letterSpacing: "-0.025em"
  title:
    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif'
    fontSize: "clamp(1.6rem, 2.4vw, 2.25rem)"
    fontWeight: 700
    letterSpacing: "-0.025em"
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif'
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.7
  label:
    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif'
    fontSize: "0.74rem"
    fontWeight: 750
    letterSpacing: "0.06em"
  code:
    fontFamily: 'ui-monospace, "SFMono-Regular", Menlo, monospace'
    fontSize: "0.8rem"
rounded:
  compact: "8px"
  small: "10px"
  control: "12px"
  transcript: "58px"
  circle: "50%"
spacing:
  control-x: "18px"
  section-x: "clamp(26px, 7vw, 104px)"
  section-y: "clamp(90px, 11vw, 160px)"
  section-gap: "clamp(48px, 9vw, 140px)"
components:
  button-primary:
    backgroundColor: "{colors.violet}"
    textColor: "{colors.white}"
    rounded: "{rounded.control}"
    padding: "0 18px"
    height: "48px"
  button-primary-hover:
    backgroundColor: "{colors.violet-bright}"
    textColor: "{colors.white}"
    rounded: "{rounded.control}"
  button-outline:
    backgroundColor: "transparent"
    textColor: "{colors.paper}"
    rounded: "{rounded.small}"
    padding: "9px 13px"
  code-row:
    backgroundColor: "{colors.code-surface}"
    textColor: "{colors.white}"
    rounded: "{rounded.control}"
    padding: "14px 14px 14px 18px"
---

# Design System: Vocaret

## Overview

**Creative North Star: "The Live Caption Control Room"**

Vocaret's public web identity makes dictation visible at working scale instead of placing a generic app mockup in the hero. Deep caption fields, sparse broadcast guides, electric violet controls, and a red live tally create the atmosphere of a precise transcription monitor. Off-white copy and macOS-adjacent controls keep that world legible and credible.

This is the visual system for public web and documentation surfaces. Native app screens continue to use macOS structure and semantic behavior; the site's broadcast geometry is a brand expression, not a replacement for platform conventions.

**Key Characteristics:**

- Dark, cinematic grounds with one light instructional section for deliberate contrast.
- Condensed uppercase display type paired with quiet system UI text.
- Live transcription shown as semantic text inside a hardware-like floating instrument.
- Violet reserved for action and brand planes; signal red reserved for active recording.
- Thin guide lines and dividers instead of repeated card containers.

## Colors

The palette is a near-black monitor field punctuated by Vocaret violet, live-signal red, cool broadcast lines, and warm off-white copy.

### Primary

- **Control Violet:** Use `violet` for the primary action and full-width brand planes; use `violet-bright` for hover, cursor, and small emphasis states.

### Secondary

- **Live Tally Red:** Use `live` only for recording, streaming, meters, or other genuinely active signal states.

### Neutral

- **Black Signal Ground:** `ink` is the page ground; `deep` and `deep-soft` create large tonal fields without turning sections into cards.
- **Monitor Paper:** `paper` is primary copy and the light installation field; `paper-muted` carries secondary copy on dark surfaces.
- **Broadcast Blue:** The two broadcast-line tokens describe guide geometry and registration marks, never interactive state.
- **Instructional Ink:** `light-ink`, `code-surface`, and `light-divider` support the light source-install section.

**The Signal Integrity Rule.** Red means live activity, violet means brand or action, and broadcast blue means non-interactive geometry; do not swap their roles.

## Typography

**Display Font:** Barlow Condensed, with Arial Narrow and sans-serif fallback
**Body Font:** the Apple system stack, with Segoe UI and sans-serif fallback
**Code Font:** the platform monospace stack

**Character:** The condensed face gives headlines the compressed authority of caption and broadcast graphics. System text keeps instructions, navigation, and transcript content familiar on macOS; monospace is limited to commands and keyboard shortcuts.

### Hierarchy

- **Display:** Oversized, uppercase, tightly led branding for the hero wordmark only.
- **Headline:** Condensed uppercase section statements, usually held to roughly 12 characters per line.
- **Title:** Bold system text for workflow steps, engine names, and local component headings.
- **Body:** Regular system text with generous leading; explanatory copy stays near 58–68 characters per line.
- **Label:** Compact, tracked, often uppercase text for status and safe-area annotations.
- **Code:** Compact monospace for shell commands and `kbd` shortcuts only.

**The Two-Voice Rule.** Barlow Condensed carries proclamation; the system stack carries comprehension. Never set paragraphs or animated transcript lines in the display face.

## Layout

Desktop pages use full-bleed sections with shared horizontal gutters from `section-x`, not a centered stack of cards. The hero is a wide stage: copy occupies the left half while the transcript instrument crosses the lower-right field and overlaps the safe-area grid. Subsequent sections alternate two-column editorial intros, three equal workflow columns, and full-width ruled rows.

The responsive thresholds are 1080px and 760px. Below 1080px, major grids collapse and the transcript expands toward the viewport edge. Below 760px, secondary navigation is hidden, content becomes one column, the workflow becomes ruled rows, and the transcript loses its rotation and uses a compact rounded shape. Section spacing stays fluid through the normative clamp tokens.

**The Field-Not-Card Rule.** Build hierarchy with full-width tonal fields, alignment, and rules. Reserve enclosed containers for functional instruments such as the transcript monitor and command rows.

## Elevation & Depth

Most surfaces are flat and separated by tonal contrast or one-pixel rules. Elevation concentrates on the transcript instrument, whose dark gradient, inset rim, and three-layer shadow make it feel like physical recording hardware. The primary action and dark command rows use smaller ambient shadows to lift controls from their fields.

### Shadow Vocabulary

- **Transcript instrument:** `0 34px 80px rgba(0, 0, 0, 0.62), 0 5px 16px rgba(0, 0, 0, 0.5), 0 0 0 8px rgba(0, 0, 0, 0.18)`; use only on the signature live-transcript surface.
- **Primary action:** `0 10px 26px rgba(27, 9, 76, 0.36)`, increasing to `0 14px 34px rgba(27, 9, 76, 0.48)` on hover.
- **Command row:** `0 10px 25px rgba(16, 19, 27, 0.16)` on the light installation field.

**The Instrument-Only Rule.** Deep elevation marks a working instrument, not ordinary content. Editorial sections remain flat.

## Shapes

Controls use compact, gently rounded corners from the `compact`, `small`, and `control` tokens. The live transcript is the exception: its broad `transcript` radius creates a horizontal equipment silhouette with a smaller inset rim. Circles belong to live tallies, orbits, and registration geometry. One-pixel borders stay cool and low-contrast.

## Components

### Buttons

- **Primary:** A 48px-high violet control with bold system text, an inline stroke icon, and compact padding. Hover brightens and lifts; active scales to 97%.
- **Outline:** A quiet transparent control with a thin pale border. Use it for GitHub or other secondary destinations.
- **Focus:** Every interactive element receives a 3px paper outline with 4px offset; do not remove it for visual polish.

### Navigation

The desktop header is a slim transparent rail with the canonical icon, wordmark, quiet text links, and one outlined destination. At mobile width, preserve the brand and final outlined destination while hiding secondary links. Navigation never becomes a floating pill.

### Live Transcript Instrument

This is the signature component: a wide black monitor with a red tally, tabular timer, animated meter, four semantic transcript lines, violet cursor, and shortcut key. It rotates slightly on desktop and becomes level on mobile. The copy cycles without moving surrounding layout; reduced motion disables the sequence and collapses animations to a single frame.

### Workflow and Engine Rows

Use shared top and bottom rules, equal columns, and direct text hierarchy rather than separate cards. Violet step numbers and small status dots are the only decoration.

### Command Rows

Each install step pairs an explanatory label with a dark code surface and compact copy action. The copied state uses a pale violet fill and dark text; the command remains selectable if clipboard access fails.

## Do's and Don'ts

### Do:

- **Do** demonstrate dictation with live semantic text, an anchored timer, and a stable four-line transcript.
- **Do** preserve the Vocaret icon's proportions and use it without decorative masking beyond the established small corner treatment.
- **Do** keep layouts full-bleed, ruled, and asymmetrical on wide screens, then stack cleanly at the established breakpoints.
- **Do** honor `prefers-reduced-motion`, visible keyboard focus, and readable small-screen contrast.

### Don't:

- **Don't** replace the caption-control-room proof with a generic laptop, phone, or app-window mockup.
- **Don't** spread live red across decorative elements or use broadcast blue for links and buttons.
- **Don't** turn editorial content into a grid of interchangeable rounded cards.
- **Don't** rasterize headlines, transcript copy, controls, or guide geometry.
- **Don't** carry the desktop transcript rotation or secondary navigation into the mobile layout.
