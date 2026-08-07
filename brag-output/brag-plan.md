# Brag Plan: Airlock

## What is this app?
A hardened, single-instance local AI backend for Windows — one command installs it, everything (hardware detection, backend choice, model pull, hardening) happens automatically in the background, and it proves itself with a real chat completion before you're ever asked to trust it.

## The angle
The real motivation: cloud AI rate limits, and the churn of third-party multi-provider routing layers that promise broad compatibility and then quietly break your actual coding workflow. Airlock's answer isn't "trust our routing" — it's "run it on your own hardware, and we'll prove it works before you touch it." One command kicks off real, non-trivial work behind the scenes — while it runs, the video explains what's actually happening: how it decides Ollama vs. vLLM, how it picks and pulls a model that fits your hardware, and how it locks the whole thing down. The payoff is the name itself: once setup finishes, a real test chat gets sent and a real response comes back — proof the seal holds, not a claim about it. Airlock isn't a decoration on the name, it's the demo's structure: something goes in, gets verified, and only then does the door open.

## Hook (first 2-3 seconds)
A terminal, blank prompt, cursor blinking. The real one-liner types out:
`irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex`
It executes. That's the entire ask of the user — everything after this is the video explaining what that one line just triggered.

## Key moments (the middle)
- Quick beat: hardware detected, GPU+Docker present decides vLLM, otherwise Ollama — the actual `Get-BackendCapability.ps1` logic, not invented for the video.
- **The centerpiece**: picking the right model size/quantization for your specific machine is normally a guess — too big and it crashes or thrashes, too small and you're leaving real capability on the table. Airlock offloads that gamble to itself: it measures your actual free RAM/VRAM, scores every candidate model against it with real headroom (not hope), and picks the largest one that genuinely fits — pulling from your local registry first, HuggingFace only if nothing local does. This is the real `Select-BestCuratedModel` / `Get-ModelSizingCeilingGB` logic (extracted and tested this session), shown as a measure → compare → pick sequence, not a wall of text.
- A quick beat locks down the hardening promise: single instance only, port blocked from outside, every action logged.
- The proof: the real "AI PLATFORM READY (Hardened)" banner lands, then a real chat completion is sent and a real response streams back on screen — captured from today's actual end-to-end test run.

## Outro / punchline
"Airlock." Then the payoff line that closes the metaphor: "Sealed. Tested. Then opened." Then the repo URL.

## User flow worth showing
Entry → key action → result, and this time the "key action" beat is itself the thing being explained:
1. Entry: the one-liner, typed into a blank terminal.
2. Key action: the real background process — hardware check, backend decision, model acquisition, hardening — narrated via on-screen text beats layered over the real running terminal (no `--voice`, so this is text, not narration).
3. Result: a real test chat sent and a real response received — the "airtight" proof, and the reason for the name.

## Tone
- Preset: app-store
- Creative direction: "authentic terminal screen-recording with an explainer layer — real commands, real colored console output, real chat response. Text beats explain the system while it's visibly working in the background, not as disconnected slide cards. No stock-photo energy, no marketing gloss — if it looks like a real machine actually doing the thing while a calm caption layer explains it, that's correct."
- Interpretation: still restrained and real. Deliberately extended past this format's normal 15-25s guidance (to ~31s) because the model-sizing decision is the actual core insight and deserves full-sentence explanation with real reading time, not compressed labels. Everything else stays lean so the extra length buys depth in one place, not padding everywhere.

## Format: landscape — 1920x1080
## Duration: 33s (extended past the format's normal 15-25s ceiling — see Tone interpretation above; retimed from an initial 31s cut once voiceover was added on 2026-08-07 — the generated Kokoro clips set the actual pace per scene, notably Scene 2's narration needing ~5.3s where the silent cut only budgeted ~3.7s)

## Visual identity (from the project)
- Background: near-black terminal (`#0C0C0C`, matches Windows Terminal's default dark theme)
- Accent: Cyan (`#00FFFF`-adjacent) — matches the `-ForegroundColor Cyan` headers used consistently across every script's console output
- Success/ready state: Green (`#3DDC84`-adjacent) — matches the real "AI PLATFORM READY" banner
- Text: White / light gray, matching real terminal body text; explainer-beat captions in the same family so they read as part of the same system, not a separate slide layer
- Display font: real monospace terminal font (Cascadia Code or Consolas) — the terminal IS the UI for this product
- Body font: same monospace throughout, including explainer captions — keeps the "this is really happening on a real machine" feeling; a clean sans (e.g. Inter) reserved only for the outro wordmark
- Strongest visual element: the real "AI PLATFORM READY (Hardened)" banner box, and the real streamed chat response — both genuinely distinctive and both literally captured from this session's real test run

## Share copy (draft)
Tired of cloud rate limits and routing layers that promise everything and break your coding session? One line installs Airlock, on your own hardware. It figures out your hardware, picks Ollama or vLLM, pulls the right model, locks the port down — then proves itself with a real test chat before you ever touch it. Proof, not a claim.

## Audio direction
- Role: sparse professional accents, not a hype bed
- Music: low, mostly-under-the-surface ambient/tech bed — restrained, denser scene count means the audio should stay out of the way even more than a simpler demo
- Music treatment: quiet under Scene 1, stays low and steady through the explainer beats, small lift under the proof scene, fades to silence under the outro
- Music cue guidance: no bundled track selected yet — detect cues at composition time (see audio.md); align one soft cue to the "READY" banner landing and one to the chat response arriving, no hard beat-grid requirement elsewhere given the restrained direction
- Audio-reactive treatment: none
- SFX posture: sparse but slightly busier than a pure demo given more beats — key ticks on the typed one-liner, a soft "tick" per explainer beat arrival, one clean confirm chime on the "READY" banner, one distinct "message received" cue when the test chat response appears (this is the emotional peak, it should sound like it)
- Audio-coupled moments: typed one-liner (key ticks), each explainer beat (soft tick), banner reveal (confirm chime), chat response arrival (message-received cue)
- Restraint rule: no music swells, no whooshes, no cinematic stingers — the message-received cue is the one moment allowed to stand out, everything else stays quiet underneath it

## Storyboard

### Scene 1 — The one-liner — 3s
A terminal window, blank prompt, cursor blinking. The real install command types out character by character: `irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex`, then executes.
Sequential/interaction: yes — simulated typing, character by character, brief settled hold before it runs.
Audio intent: quiet anticipation.
Audio-coupled idea: subtle key-tick per character.
Music: low ambient bed starts here.
Transition mood: clean cut → Scene 2.

### Scene 2 — Which backend — 4s
The real installer/`ai-start` terminal output keeps visibly running (smaller in frame, slightly dimmed but legible), while 2 short text beats reveal over it: "Checks for a GPU and Docker." → "Both present → vLLM. Otherwise → Ollama."
Sequential/interaction: yes — 2 beats, ~1.3-1.5s settled hold each; terminal continues scrolling underneath throughout.
Audio intent: quick, matter-of-fact.
Audio-coupled idea: soft tick as each beat arrives.
Music: continues low.
Transition mood: clean wipe → Scene 3.

### Scene 3 — The gamble, offloaded (centerpiece) — 11s
The real machine's true insight, given full room to land. Terminal still visible/dimmed in background throughout.
Beat 1 (~3s): Text: "Picking the right model size is normally a guess — too big crashes or thrashes, too small wastes what your machine can actually do." Visual: a small dice/question-mark motif fades as the line settles.
Beat 2 (~2.5s): Text: "Airlock measures your real free RAM and VRAM first." Visual: a capacity meter fills and locks in on real numbers — "127.7 GB RAM · 16 GB GPU" (the actual figures from today's test run).
Beat 3 (~2.5s): Text: "Then scores every candidate model against it — with headroom, not hope." Visual: 4 model-size cards appear side by side (e.g. 4.7GB / 9GB / 14GB / 18GB), a fit-check sweeps across them.
Beat 4 (~3s): Text: "Picks the largest one that actually fits — pulls it from your local registry, or HuggingFace if nothing local does." Visual: cards that don't fit gray out and shrink; the winning card highlights green with a checkmark and slides forward.
Sequential/interaction: yes throughout — this whole scene IS a sequential reveal (meter fills → cards compared → non-fits eliminated → winner locks in). This is the single most important sequence in the video; nothing here should feel rushed.
Audio intent: this is where "explaining" becomes "demonstrating" — steady, confident, building toward the winner-card reveal.
Audio-coupled idea: soft tick on the meter filling; a distinct "elimination" tick as non-fitting cards gray out; a slightly brighter confirm tick when the winner locks in.
Music: continues low, no swell — the visual sequence carries the weight, not the audio.
Transition mood: clean slide → Scene 4.

### Scene 4 — What it locks down — 4.5-5s
Terminal still visible/dimmed in background. 4 short text beats: "One instance, ever." → "Port blocked from the outside." → "Every action logged." → "Remembers your session — when it's running on Ollama."
Sequential/interaction: yes — beats arrive in sequence, ~1-1.2s settled hold each.
Audio intent: confident, matter-of-fact — the hardening promise, stated plainly and quickly since Scene 3 already carried the depth.
Audio-coupled idea: soft tick per beat.
Music: continues low.
Transition mood: clean slide → Scene 5.

### Scene 5 — Proof — 5s
Terminal snaps back to full focus. The real colored "AI PLATFORM READY (Hardened)" banner appears (Endpoint, `Bind: 127.0.0.1 ONLY`, `Firewall: Protected`). Then a real chat prompt is sent and a real response streams onto screen — the actual captured exchange from today's test.
Sequential/interaction: yes — banner reveals line by line and holds briefly; then the prompt appears, then the response streams in.
Audio intent: payoff — the emotional peak of the video.
Audio-coupled idea: confirm chime on the banner completing; distinct "message received" cue as the response lands.
Music: small lift here, still restrained, not a swell.
Transition mood: clean crossfade → Scene 6.

### Scene 6 — Outro — 4s
Clean dark card: "Airlock" wordmark, then "Sealed. Tested. Then opened.", then "github.com/veeresh-bikkaneti/airlock" in small type.
Sequential/interaction: none — three lines settle in with a brief stagger, then hold.
Audio intent: quiet close, the metaphor lands.
Audio-coupled idea: none.
Music: fades to silence across this scene.
Transition mood: — (end)

**Music mood for this video:** restrained tech/ambient, near-silent presence except one distinct "message received" cue at the proof moment and light rhythmic ticks through the Scene 3 comparison sequence.
**Audio summary:** Quiet ambient bed under sparse ticks through Scenes 2-4, a slightly busier (but still restrained) tick pattern through Scene 3's card-comparison sequence since that's doing real visual work, one confirm chime on the ready banner, one standout "message received" cue on the real chat response (the emotional peak), then fades to nothing by the outro.

## Voiceover script

Added 2026-08-07 per explicit request. Six lines, one per scene, natural spoken phrasing (not a read-aloud of the on-screen captions). Kokoro voice `af_heart`. Scene durations retime to match each generated clip's real length — voice sets the pace, not the other way around.

1. (Scene 1 — hook) "One line. That's the whole install."
2. (Scene 2 — backend) "It checks your hardware — a GPU and Docker means V L L M, otherwise Ollama."
3. (Scene 3 — centerpiece) "Picking the right model size is normally a guess. Airlock measures your real memory first, scores every model against it, and picks the biggest one that actually fits."
4. (Scene 4 — lockdown) "Then it locks everything down — one instance, port blocked, fully logged. On Ollama, it even remembers your session."
5. (Scene 5 — proof) "And it proves itself — a real response, before you ever touch it."
6. (Scene 6 — outro) "Airlock. Sealed, tested, then opened."

~80 words total (added memory-service line on 2026-08-07), targets ~33-35s at natural pace (2.5 words/sec) with room for pauses — actual scene lengths follow whatever Kokoro actually renders.
