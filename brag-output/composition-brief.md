# Hyperframes Composition Brief: Airlock

## Objective
Create a short launch-style brag video for Airlock — but structured as a real explainer-while-it-installs demo, not a pure hype reel: one real command runs, while it does real work in the background the video explains how the system decides things, then proves itself with a real chat completion.

## Output
- Composition directory: `brag-output/composition/`
- Rendered video: `brag-output/brag.mp4`
- Format: landscape — 1920x1080
- Duration: ~44.9 seconds (deliberately extended past this format's normal 15-25s guidance — the model-sizing scene is the product's core insight and needed real reading room, Scene 4 gained a memory-service beat after the first render, a Scene 6 bonus beat for the 3D system visualizer was added before the outro, and Scene 6 gained a third beat for the visualizer's data-depth pass; see brag-plan.md's Tone interpretation for the reasoning)

## Source Material
- Project root: `C:\Users\veere\source\repos\local-ai-platform`
- Primary files read/referenced: `README.md`, `scripts/Start-AI.ps1`, `scripts/Get-BackendCapability.ps1`, `scripts/Get-ModelAcquisition.ps1` (`Select-BestCuratedModel`, `Get-ModelSizingCeilingGB`), real console output and real audit-log entries captured from today's live end-to-end test run of this exact repo
- Product name: Airlock
- Tagline / strongest claim: "One door open at a time." / "Proof, not a claim."
- Key UI or visual moment to recreate:
  - The real one-liner install command (verbatim, see below)
  - The real colored "AI PLATFORM READY (Hardened)" console banner
  - A real chat completion request/response pair (verbatim, from today's test — see below)
  - The real `tools/3d-system-visualizer` node graph (captured screenshot at `tools/3d-system-visualizer/preview.png`, mid-workflow-playback), used as Scene 6's background
- Copy that must appear verbatim:
  - `irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex`
  - `AI PLATFORM READY (Hardened)`
  - `Endpoint: http://127.0.0.1:12345/v1`
  - `Bind: 127.0.0.1 ONLY (no external)`
  - `Firewall: Inbound port 12345 BLOCKED`
  - Chat exchange: user message "Say hello world and nothing else." → assistant response "Hello, what do you need help with?" (this is the real, unedited response captured from the real qwen2.5:0.5b model during today's test — do not clean it up into a more "perfect" answer, the point is that it's real)
  - "Airlock." / "Sealed. Tested. Then opened." / "github.com/veeresh-bikkaneti/airlock"

## Creative Direction
- Tone preset: app-store
- Creative direction: authentic terminal screen-recording with an explainer layer laid over real running output — real commands, real colored console output, real chat response. Text beats explain the system while it visibly keeps working in the background, not as disconnected slide cards. No stock-photo energy, no marketing gloss, no cinematic swells.
- Interpretation: clean, confident, restrained. The terminal is the UI and never fully disappears behind explainer text. The one genuine emotional peak is the real chat response arriving in Scene 5 — that's the only moment allowed to feel like a "reveal"; everything else stays matter-of-fact.
- Angle: cloud AI rate limits and flaky third-party multi-provider routing layers are the real motivation — Airlock's answer is "run it on your own hardware, and we'll prove it works before you touch it," not "trust our routing." One command triggers real work; the video explains what's happening while it happens, then proves the result with a real test chat.
- Hook: blank terminal, cursor blinking, the real one-liner types out character by character and executes.
- Outro / punchline: "Airlock." → "Sealed. Tested. Then opened." → repo URL. Quiet, not a slam.
- Avoid:
  - Generic SaaS language ("streamline your workflow" etc.)
  - Abstract filler visuals — every scene must show something real (real terminal text, real banner, real chat, or a direct visualization of the real decision logic)
  - Unrelated visual redesign — this is a CLI/terminal product, the aesthetic should look like a real terminal recording, not an invented "app" UI
  - Music swells, whooshes, or cinematic stingers — restraint is a stated requirement, not a default to override

## Visual Identity
- Background: near-black terminal, `#0C0C0C` (Windows Terminal default dark theme — this is what the real product actually looks like on screen)
- Text: white/light gray body text, matching real terminal output
- Accent: Cyan, `#00FFFF`-adjacent — matches `-ForegroundColor Cyan` used consistently for headers across every real script in this product (`Start-AI.ps1`, `Stop-AI.ps1`, `setup.ps1`, `install.ps1`)
- Success/ready accent: Green, `#3DDC84`-adjacent — matches the real "AI PLATFORM READY" banner's actual color
- Display font: real monospace terminal font (Cascadia Code or Consolas) — used throughout, including explainer captions, so they read as part of the same real system rather than a separate slide layer
- Body font: same monospace; a clean sans (e.g. Inter) reserved only for the outro wordmark card
- Visual references from the project: the real "AI PLATFORM READY (Hardened)" banner box styling (colored ASCII-box structure already used in the product's own console output) and the real captured chat exchange

## Storyboard
Use the storyboard in `brag-output/brag-plan.md` as the creative contract — full beat-by-beat detail lives there. Scene summary:

1. **The one-liner** — 3s — blank terminal, the real install one-liner types out character by character, executes.
2. **Which backend** — 4s — real installer/`ai-start` output keeps running (dimmed, backgrounded); 2 short text beats: "Checks for a GPU and Docker." → "Both present → vLLM. Otherwise → Ollama."
3. **The gamble, offloaded (centerpiece)** — 11s — the model-sizing decision, given full room. 4 beats, each paired with a visual step: (1) framing the problem — picking model size is normally a guess; (2) a capacity meter fills to real numbers, "127.7 GB RAM · 16 GB GPU"; (3) 4 model-size cards appear (4.7GB/9GB/14GB/18GB), a fit-check sweeps across them; (4) non-fitting cards gray out and shrink, the winning card highlights green with a checkmark and slides forward, paired with text explaining the pull source (local registry first, HuggingFace fallback). This is the single most important sequence in the video — do not rush it.
4. **What it locks down** — 7.1s — 4 short beats over the still-visible dimmed terminal: "One instance, ever." → "Port blocked from the outside." → "Every action logged." → "Remembers your session — on Ollama."
5. **Proof** — 5s — terminal snaps to full focus; real "AI PLATFORM READY (Hardened)" banner reveals line by line and holds; then the real chat prompt appears, then the real response streams in. This is the emotional peak.
6. **Bonus: the system in 3D** — 9.2s — clean cut to the real captured `tools/3d-system-visualizer` node graph (`preview.png`), same near-black background as the terminal. Slow camera drift/zoom over the real frame; a small dot travels the real edge path (Client → API Gateway → Orders Service → Payments Service → Ledger DB), recreating the tool's actual "Place order (happy path)" workflow playback. 2 text beats: "There's more than the terminal." → "A 3D map of how every piece actually talks to each other — free, in `tools/`." Then a third beat: the camera settles back to the full frame and crossfades to a second real capture (`viz-3d-data-depth.png`) showing the tool's data-depth pass — the scene-picker panel, a status-tinted node, and an open inspect panel — with the caption "Now you can load your own map and click anything to inspect it." Silent, no new voiceover. A light aside, not a second peak.
7. **Outro** — 4s — "Airlock" wordmark → "Sealed. Tested. Then opened." → repo URL, staggered settle, quiet hold.

## Audio
- Audio role: sparse professional accents over a low, mostly-under-the-surface ambient bed — never a hype layer
- Audio arc: quiet under the hook, steady low presence through the explainer scenes (slightly busier — but still restrained — ticking through Scene 3's card-comparison sequence since that scene is doing real visual work), one confirm chime on the ready banner, one standout cue on the real chat response (the one moment allowed to be distinct), fade to silence under the outro
- Music: `assets/music/happy-beats-business-moves-vol-12-by-ende-dot-app.mp3` ("Steady and clean," polished/cinematic character fits the restrained, real-terminal direction better than the more energetic tracks) at 0.25-0.3 volume (below the normal 0.3-0.4 band, since this video wants restraint over energy)
- Music treatment: fade in under Scene 1 (first ~0.5s), hold low and steady through Scenes 2-4, a very slight lift (still ≤0.3) under Scene 5's proof moment, fade to silence across Scene 6
- Music cue guidance: no bundled cue preset confirmed available yet — attempt `npx hyperframes beats brag-output/composition` after the music is wired in; if unavailable, proceed with natural (non-beat-locked) timing and note it. Given the restrained direction, use at most 1 strong-cue lock (the chat-response arrival in Scene 5) if a cue source exists — do not force other moments onto the grid.
- Audio-reactive treatment: subtle — if a music cue/RMS source is available, let the Scene 3 capacity-meter fill and/or the winning model card's glow breathe very slightly with the music's RMS. No waveform/equalizer visuals, no strobing.
- Audio-coupled moments:
  - Scene 1 typed one-liner — per-character key-tick, randomized from `keyboard/keypress-*.wav`
  - Scene 2 & 4 explainer beats — soft `interface/drop_001` or `drop_002` per beat arrival
  - Scene 3 meter fill — soft tick as it fills; a distinct "elimination" tick (e.g. `ui/switch*` or `interface/switch_001`) as non-fitting cards gray out; a slightly brighter confirm tick (`interface/select_008` or similar) when the winning card locks in
  - Scene 5 banner reveal — `impact/impactBell_heavy_000` as the banner completes (matches this product's own "big reveal" banner styling)
  - Scene 5 chat response arrival — a distinct, different bell (e.g. `impact/impactBell_heavy_004`) as the real response lands — this is the video's true emotional peak, it should sound different from the banner chime, not just a repeat of it
  - Scene 6 workflow dot travel — reuse the same soft tick family as Scenes 2/4 as the dot passes each node — do not introduce a new sound for this bonus beat
  - Scene 7 outro — no SFX; let the fade-out and the real product speak for itself
- SFX selection guidance: prefer low/medium high-frequency-risk files per `sfx-analysis.md` for the repeated Scene 2-4 beat ticks (these repeat several times across the video); reserve the two bell moments (Scenes 5) for the only two "big" sounds in the whole piece so they actually stand out
- SFX analysis guidance: read `sfx-analysis.md` (bundled beside the SFX library) before finalizing exact files
- Exact SFX choice: Hyperframes should pick final filenames, timestamps, density, and volume once the animation exists — the above is guidance, not a locked cue sheet
- Audio files: copy the chosen music track and any Hyperframes-selected SFX into `brag-output/composition/assets/`

## Hyperframes Instructions
Load the composition-building Hyperframes domain skills — `hyperframes-core` (composition contract + `data-*` timing), `hyperframes-animation` (motion), `hyperframes-creative` (design spec, beats, audio-reactive), `hyperframes-keyframes` (seek-safe keyframes), and `hyperframes-cli` (lint/check/render). `/brag` is its own workflow: do not enter the `hyperframes` entry-point intent interview and do not route into its generic promo/launch-video workflow. Prefer native Hyperframes conventions over anything hardcoded in this brief.

Requirements:
- Show real terminal text, the real banner, and the real chat exchange verbatim — this is a CLI product, the terminal recording IS the demo.
- Keep all text readable in the final render, especially the Scene 3 explainer beats — this scene got extended screen time specifically so its text isn't rushed.
- Scene 6: copy `tools/3d-system-visualizer/preview.png` into `composition/assets/` and use it as the scene's background image; do not fabricate a different node graph — the real captured screenshot is the visual. Beat 3 (added 2026-08-07) crossfades to a second real capture, `viz-3d-data-depth.png`, showing the tool's data-depth pass (scene picker, status glow, inspect panel) — same rule: the real captured screenshot is the visual, nothing fabricated.
- Total duration ~44.9 seconds (see Output section above for why this exceeds the format's normal ceiling).
- Include the planned music/SFX layer as described above.
- Treat the audio notes above as guidance, not a fixed cue sheet — choose exact SFX after the visual animation exists.
- Use at most 1-3 strong cue locks if a beat/cue source is available; do not force other moments onto a beat grid.
- Honor the planned music treatment (fade-in, steady low hold, slight lift at the proof moment, fade-out at the outro).
- If a music cue/RMS source is available, wire one subtle audio-reactive element (Scene 3's meter or winning card) per the guidance above; if extraction is unavailable, skip it and note that rather than blocking the render.
- Use local assets copied into `composition/assets/` — no absolute paths.
- Run `hyperframes check` before render — it is the single gate before delivery.
