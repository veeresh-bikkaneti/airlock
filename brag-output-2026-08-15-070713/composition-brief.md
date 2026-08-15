# Hyperframes Composition Brief: Airlock

## Objective
Create a short, cinematic-but-deadpan launch video for Airlock — a hardened, single-instance local AI platform for Windows.

## Output
- Composition directory: `brag-output-2026-08-15-070713/composition/`
- Rendered video: `brag-output-2026-08-15-070713/brag.mp4`
- Format: landscape — 1920x1080
- Duration: 20 seconds

## Source Material
- Project root: repo root (`C:\Users\veere\source\repos\local-ai-platform`)
- Primary files read: `README.md`, `tools/airlock-manual/index.html` (the closest thing this repo has to a product site — real CSS custom properties, real animated diagrams, real capability data), `package.json`
- Product name: Airlock
- Tagline / strongest claim: "One door open at a time — exactly one local model backend running, walled off from the outside, everything logged."
- Key UI or visual moment to recreate: the `ai-doctor` animated decision-flow diagram from `tools/airlock-manual/index.html` (a token traveling a real diagnostic path to "ORPHANED POINTER"), and the manual's CSS 3D exploded architecture stack (5 layers, amber "gated" cloud layer at the bottom)
- Copy that must appear verbatim:
  - "ONE DOOR OPEN AT A TIME."
  - "ORPHANED POINTER."
  - "It tells you the truth, even about itself."

## Creative Direction
- Tone preset: `cinematic`
- Creative direction: blend specified by the user — cinematic scale for motion/reveals, polished restraint for confidence, deadpan delivery for every line of copy
- Interpretation: wide shots, dramatic wipes, a slow-building swell — but every caption reads as a flat status line, never a punchline. The "not wired" pill in Scene 4 gets exactly the same visual/audio treatment as the "live" pills before it. That flatness is the joke.
- Angle: Most launch videos hide the seams. Airlock's actual design premise is refusing to — this video plays that completely straight and lets the platform's own honesty (including an admitted "not wired" gap) be the impressive claim.
- Hook: "ONE DOOR OPEN AT A TIME." slams in on a black console screen, one swell rising underneath.
- Outro / punchline: Wordmark "AIRLOCK" lands on one dry hit. "It tells you the truth, even about itself."
- Avoid:
  - Generic SaaS language ("streamline," "empower," etc. — none of it appears anywhere in this brief on purpose)
  - Abstract filler visuals — every scene shows a real, sourced element (the stack diagram, the doctor flow, the showcase pills), nothing invented
  - Any comedic sting, laugh-track energy, or triumphant fanfare — restraint is load-bearing to this tone

## Visual Identity
- Background: `#0c100e` (darkest console token from the manual's dark-mode `--console-bg`)
- Text: `#dcd8c9` (`--console-ink`, dark mode)
- Accent: `#e8a23c` (amber, primary) and `#4fc3b8` (teal, secondary/status-good); `#e0665a` (danger/red) only for the briefest instant if the "not wired" pill needs it, kept restrained
- Display font: "Cascadia Code", "JetBrains Mono", ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace
- Body font: ui-sans-serif, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif
- Visual references from the project: `tools/airlock-manual/index.html` — its `.stack-scene` 3D layer treatment, its `.screen`/`.node-box`/`.token` diagram language, and its `.pill.live`/`.pill.proposed`/`.pill.notwired` status-badge styling. Reuse the color/shape language; don't invent a new visual system.

## Storyboard
Use the storyboard in `brag-output-2026-08-15-070713/brag-plan.md` as the creative contract.

Scene summary:
1. Hook — 3s — "ONE DOOR OPEN AT A TIME." slams in; "Everything else stays sealed." settles beneath.
2. Reveal — 4s — 3D exploded stack, 5 layers arriving top to bottom, cloud layer (amber, gated) distinct.
3. Key moment 1 — 5s — `ai-doctor` token travels its real decision path to "ORPHANED POINTER," typed caption explains the real 2-hour incident.
4. Key moment 2 — 4s — 3 capability rows arrive in sequence (live, live, then a longer hold on "not wired").
5. Outro — 4s — Wordmark "AIRLOCK" lands on a dry hit; "One door open at a time." / "It tells you the truth, even about itself."

## Audio
- Audio role: cinematic support, restrained, motion-matched
- Audio arc: quiet pulse → rising swell through the hook and stack reveal → drop to a quiet floor for the two "proof" scenes so typed/read copy stays legible → one dry hit on the wordmark → fade
- Music: none selected yet — choose a cinematic-mood track from the skill's bundled library at composition time
- Music treatment: swell under Scene 1, peaking as Scene 2's last layer lands; quiet floor under Scenes 3-4; single resolving hit under Scene 5, then fade
- Music cue guidance: detect at composition time (`analyze_music_cues.py` or `npx hyperframes beats` on whichever track is chosen). Target 3 strong-cue locks: end of Scene 1, end of Scene 2, start of Scene 5. Scene 4's 3-row sequence should use a beat-grid window if available; otherwise hold each row to its reading floor rather than force a snap.
- Audio-reactive treatment: subtle — the amber/teal glow already present on active nodes/pills may breathe slightly with music energy in Scenes 2-4. No waveform bars, no visualizer look.
- Audio-coupled moments:
  - Scene 2 — 5 stack layers arriving, each with its own tick; cloud layer's tick is distinct/cooler
  - Scene 3 — token hops (tick per node) plus a typing sound under the character-by-character caption
  - Scene 4 — card-by-card sequence; the "not wired" row's tick is deliberately duller/lower than the two "live" ticks, not a comedic sting
- SFX selection guidance: sparse-to-moderate, entirely motion-matched, no whooshes or cartoon stingers. Prefer restrained, low high-frequency-risk sounds given how much of this video is quiet-and-deliberate rather than upbeat.
- SFX analysis guidance: use `skills/brag/assets/sfx/sfx-analysis.md` if present for exact file selection.
- Exact SFX choice: Hyperframes chooses filenames, timestamps, density, and volume based on the implemented animation.
- Audio files: copy chosen music and any selected SFX into `brag-output-2026-08-15-070713/composition/assets/`.

## Hyperframes Instructions
Load the composition-building Hyperframes domain skills — `hyperframes-core` (composition contract + `data-*` timing), `hyperframes-animation` (motion), `hyperframes-creative` (design spec, beats, audio-reactive), `hyperframes-keyframes` (seek-safe keyframes), and `hyperframes-cli` (lint/check/render). `/brag` is its own workflow: do not enter the `hyperframes` entry-point intent interview and do not route into its generic promo/launch-video workflow. Prefer native Hyperframes conventions over anything hardcoded in `/brag`.

Requirements:
- Show at least one real UI, copy, or visual element from the source project (the doctor flow and the 3D stack both qualify — both are real, both already exist in `tools/airlock-manual/index.html`).
- Keep all text readable in the final render — hold every line to at least its reading floor per `step-2-plan.md`.
- Keep the video within 15-25 seconds (target 20s).
- Include the planned music/SFX layer (not disabled, not documented as intentionally silent).
- Treat the audio notes above as guidance, not a fixed cue sheet — choose exact SFX after the visual animation exists.
- Treat music cue metadata as optional timing hints; ignore any cue that hurts readability, pacing, or the story.
- Use 1-3 strong-cue locks max in this 20s video, per the plan above.
- Use SFX to support motion and interaction as described; restraint where the edit is already busy.
- Honor the planned music treatment (swell, drop to floor, final hit, fade).
- Wire in subtle audio-reactive glow per the guidance above; skip and document if extraction is unavailable — do not block the render on it.
- Use local assets where possible.
- Run `hyperframes check` before render — it is `/brag`'s single gate.
