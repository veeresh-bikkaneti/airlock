# Brag Plan: Airlock

## What is this app?
A hardened, single-instance local AI platform for Windows — Ollama/vLLM behind a PowerShell CLI, cloud fallback locked behind an explicit, audited switch. Also, apparently, a platform whose own documentation contains a diagram admitting which features aren't wired up yet.

## The angle
Most launch videos hide the seams. Airlock's whole design premise is refusing to hide seams — a permanent settings-file redirect once caused a real two-hour outage, so every subsequent design decision exists to make that class of failure loud instead of silent. The video's angle: play it completely straight, trailer-scale, and let the honesty itself be the impressive claim. The capabilities showcase literally has a "not wired" badge on a real feature. That's the hook, not something to cut around.

## Hook (first 2-3 seconds)
Black console screen. One line slams in, huge, monospace: **"ONE DOOR OPEN AT A TIME."** A beat of silence-except-the-swell, then smaller beneath it: "Everything else stays sealed."

## Key moments (the middle)
- The `ai-doctor` decision flow actually running: a token travels the real diagnostic path from the manual and lands on "ORPHANED POINTER" — stated flatly, no dramatic sting, because the point is that the platform found this itself.
- Three rows from the capabilities showcase arriving one by one — `live`, `live`, then held a beat longer on `not wired` for the cloud-key routing. The pause on the honest admission is the joke, delivered completely deadpan.

## Outro / punchline
Wordmark "AIRLOCK" lands on a single dry hit, no fanfare. Final line: **"It tells you the truth, even about itself."**

## User flow worth showing
1. Entry — `ai-start` seals the airlock: one clean local backend, firewalled port.
2. Key action — `ai-doctor` catches a redirect pointed at a dead address and tells you whether it's a two-second fix or something that needs a reboot.
3. Result — `ai-claude-on` puts Claude Code on the local model for this terminal only, gone the moment you're done.

## Tone
- Preset: `cinematic` (base for pacing/scene count/camera language)
- Creative direction: user-specified blend — cinematic scale for motion and reveals, polished restraint for confidence (no cheap jokes, no clutter), deadpan delivery for every line of copy (facts stated flatly, drama comes from motion and music, never from the writing).
- Interpretation: big wide shots and dramatic wipes (cinematic), but every caption reads like a matter-of-fact status line, not a punchline (deadpan) — and nothing in the frame is ever crowded or cute (polished). The "not wired" pill is played as seriously as the "live" pills; that contrast is where the humor actually lives.

## Format: landscape — 1920x1080
## Duration: 20s target

## Visual identity (from the project)
- Background: `#0c100e` (the manual's darkest console token — `--console-bg` under an explicit dark toggle)
- Accent: `#e8a23c` (amber, primary) and `#4fc3b8` (teal, secondary/status-good)
- Text: `#dcd8c9` (`--console-ink`, dark mode)
- Display font: "Cascadia Code", "JetBrains Mono", ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace
- Body font: ui-sans-serif, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif
- Strongest visual element: the animated `ai-doctor` orphaned-pointer decision flow and the CSS 3D exploded architecture stack — both real, both already built and running in `tools/airlock-manual/index.html`, not recreated from imagination

## Share copy (draft)
Airlock: one door open at a time. A hardened, single-instance local AI platform for Windows — and probably the only launch video that includes the slide admitting what doesn't work yet.

## Audio direction
- Role: cinematic support with restrained, motion-matched accents
- Music: cinematic bed, low swell building through the hook and reveal, settling under the middle scenes, resolving to near-silence before the final dry hit
- Music treatment: swell starts under Scene 1's hook text, peaks as Scene 2's stack layers finish arriving, drops to a quiet floor under Scenes 3-4 so dialogue-style captions read clearly, one low restrained hit under the wordmark landing in Scene 5, then fade
- Music cue guidance: to be detected at composition time (no specific bundled track chosen yet — Hyperframes/`analyze_music_cues.py` picks the exact track and cues). Target 3 strong cues: end of Scene 1 (hook lands), end of Scene 2 (last stack layer arrives), start of Scene 5 (wordmark hit). Scene 4's card-by-card reveal wants a beat-grid window if the chosen track has one; if not, hold each card to its reading floor rather than snapping to an arbitrary interval.
- Audio-reactive treatment: subtle — the amber/teal glow already used on active nodes/pills in the source manual may breathe slightly with music energy under the stack and showcase scenes; never waveform bars, never anything that reads as a music visualizer
- SFX posture: sparse-to-moderate, entirely motion-matched — a soft tick per stack layer landing, a soft tick per token hop in the doctor diagram, a typing sound under the one typewriter caption, a distinct (slightly duller/lower) tick for the "not wired" pill specifically. No whooshes, no cartoon stingers, no laugh-track energy anywhere.
- Audio-coupled moments: Scene 2's 5 layers arriving top to bottom; Scene 3's token traveling node to node plus its typed caption; Scene 4's showcase rows arriving one by one
- Restraint rule: no comedic timing, no all-caps screaming type, no triumphant fanfare on the outro — the reveal that a feature is "not wired" gets exactly the same visual and audio treatment as a "live" one. That flatness is the entire joke.

## Storyboard

### Scene 1 — Hook — 3s
Full-bleed `#0c100e` console black. A single amber status dot (the manual's own "lamp" element) pulses once, quiet. Then huge monospace type slams in center frame: "ONE DOOR OPEN AT A TIME." A half-second later, smaller text settles beneath it: "Everything else stays sealed."
Sequential/interaction: none — one slam, one settle
Audio intent: a single low cinematic swell rising under the slam, restrained, no crash
Audio-coupled idea: the headline hits exactly on the swell's rising edge
Music: cinematic bed, quiet start
Transition mood: dramatic wipe → Scene 2

### Scene 2 — Reveal — 4s
The manual's own 3D exploded architecture stack, recreated at video scale: five layers materialize top to bottom — Terminal, CLI, Backend, memory-service (dashed, "optional"), Cloud (amber outline, "gated"). Camera holds a slow cinematic tilt matching the page's own ambient drift.
Sequential/interaction: yes — 5 layers arrive one by one, top to bottom, each landing with a soft low tick; the amber "gated" cloud layer at the bottom gets a distinct cooler-toned tick, marking it as different from the rest
Audio intent: swell peaks as the final (cloud) layer lands, then eases
Audio-coupled idea: each layer's arrival synced to its own tick
Music: cinematic bed, swell peaking at scene end
Transition mood: soft crossfade → Scene 3

### Scene 3 — Key moment: the real incident — 5s
Recreate the manual's animated `ai-doctor` diagram: a small glowing token travels the real decision path — "redirect set?" → "anything answering?" → "set somewhere permanent too?" — landing on a box that outlines in amber. Beneath it, a caption types out character by character, flat and factual: "A dead setting looked identical to a live one. It cost two hours." Then, held: "ORPHANED POINTER." and smaller: "ai-doctor tells you which one you're looking at."
Sequential/interaction: yes — token hops node to node (same path the real diagram animates), caption types character by character
Audio intent: dry restraint — one soft tick per node the token lands on, typing ticks under the caption, no dramatic sting when it lands on ORPHANED POINTER
Audio-coupled idea: typing sound synced to the caption; node-arrival ticks synced to the token's hops
Music: drops to a quiet floor so the typed caption reads clearly
Transition mood: hard cut (deadpan beat, no soft fade) → Scene 4

### Scene 4 — Key moment: the honest showcase — 4s
Rows from the manual's real capabilities showcase arrive one by one, each with its actual status pill: "Single-instance local model serving — live." "Retrieval-augmented chat — live." Then, held noticeably longer than the others: "A stored cloud key actually routing a request — not wired."
Sequential/interaction: yes — 3 rows arrive in sequence, pill badges highlighting as each lands; the third row holds roughly twice as long as the first two
Audio intent: light, restrained card-arrival ticks; the "not wired" pill's tick is deliberately duller/lower than the two "live" ticks before it — not a joke sting, just a different, honest sound
Audio-coupled idea: card-by-card sequence, each pill's landing gets its own tick
Music: stays at the quiet floor from Scene 3
Transition mood: soft crossfade → Scene 5

### Scene 5 — Outro / punchline — 4s
Back to full-bleed console black. Centered wordmark "AIRLOCK" lands in the display monospace font on a single low, dry hit — no fanfare. Beneath it, smaller: "One door open at a time." Then, smaller still, the final line: "It tells you the truth, even about itself." Footer, small: the repo path.
Sequential/interaction: none — one landing, two settles
Audio intent: the one deliberate low hit of the whole video, then fade to silence
Audio-coupled idea: wordmark impact synced exactly to the hit
Music: resolves and fades under the final line
Transition mood: n/a (end)

**Music mood for this video:** cinematic, restrained — a slow-building swell and a single dry landing, not an upbeat or triumphant bed.
**Audio summary:** Quiet dot, rising swell through the hook and the stack reveal, a deliberate drop to near-silence for the two "proof" scenes so the typed caption and the honest pill both read clearly without competing with music, then one dry hit on the wordmark and out.
