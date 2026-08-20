# ADR-010: Documentation-as-scenes — animated architecture docs Claude Code can reliably author

## Status
Proposed. Builds on the existing `tools/3d-system-visualizer/`.

## Context

### The problem, stated precisely

Asking Claude Code to "build animated, sci-fi-style documentation of the architecture" reliably produces disappointing output. The failure is predictable and it is not a model-capability problem in the way it looks:

- The task is **unbounded**. "Make it look like a sci-fi movie" has no acceptance criterion, so there is nothing to iterate against and every attempt is a fresh guess.
- The task asks for a **renderer**, not content. Each attempt reinvents WebGL/canvas plumbing, camera control, easing, and layout: hundreds of lines where a single mistake yields a blank screen and no useful error.
- There is **no feedback loop**. The agent cannot see the output. A visual bug is invisible to it, so it cannot converge.
- It is **stateless across attempts**. Nothing accumulates; version three is not better than version one.

Meanwhile `tools/3d-system-visualizer/index.html` already is the thing that keeps getting reinvented, badly: 920 lines of Three.js with a documented scene schema, animated workflow playback where a glowing head with a fading trail travels the real call path, latency-coloured edges, `healthy`/`degraded`/`down` node glow, click-to-inspect metadata panels, scene validation that catches edges referencing missing nodes, a scene picker with `?scene=` URL loading, and `Generate-LiveScene.ps1`, which turns the platform's own audit log into a scene. It is the most distinctive asset in the repo and it is buried under a `python -m http.server` instruction near the bottom of the README.

### The reframe

The renderer is not the deliverable. It exists. The deliverable is **scene JSON**, and authoring JSON against a published schema with a validator is a task LLMs do well: bounded, checkable, and mechanically verifiable without seeing pixels.

So the decision is to stop asking Claude Code to animate, and start asking it to describe. The schema is the contract, the validator is the feedback loop, and the existing renderer supplies all the sci-fi.

### What the schema is missing for teaching

Current shape, from `scenes/ecommerce-demo.json`:

```json
{ "nodes": [{ "id", "label", "pos": [x,y,z], "type", "description", "owner", "status" }],
  "edges": [{ "from", "to", "label", "protocol", "latencyMs" }],
  "flows": [{ "name", "path": ["a","b","c"], "loop", "speed" }] }
```

A flow animates the path but says nothing while doing it. For a beginner that is a pretty animation, not an explanation. They see a dot move from `Start-AI.ps1` to `Ollama` with no idea why. Teaching needs narration attached to each hop, and pacing the reader controls.

## Decision

**D1: publish the scene schema as a contract.** Add `tools/3d-system-visualizer/scenes/schema.json` (JSON Schema draft 2020-12) describing nodes, edges, and flows exactly as the renderer consumes them, and `scripts/Test-Scene.ps1` validating every scene in `manifest.json` against it. CI runs the validator, so a malformed scene fails the build rather than showing a broken screen.

**D2: extend flows with an optional narration track**, backwards compatible so existing scenes keep working:

```json
{ "name": "First run: ai-start",
  "path": ["user", "start_ai", "policy", "ollama", "endpoint"],
  "steps": [
    { "caption": "You run ai-start.", "detail": "One command. No ports to remember." },
    { "caption": "Airlock reads your saved backend choice.", "detail": "provider-policy.json holds intent, what you asked for." },
    { "caption": "Ollama starts on 127.0.0.1:12345, and only there.", "detail": "Loopback only. A firewall rule blocks inbound as defence in depth." }
  ],
  "mode": "guided", "loop": false }
```

`steps[i]` corresponds to hop `i` of `path`. `mode: "guided"` pauses at each hop and shows the caption with next/previous controls; `mode: "auto"` (default) preserves today's looping behaviour. A flow with no `steps` behaves exactly as now.

**D3: ship a beginner onboarding scene, `scenes/airlock-first-run.json`**, as the default scene in the manifest. It narrates what `ai-start` actually does (backend selection, single-instance enforcement, port binding, firewall guard, model auto-selection), precisely the set of things a newcomer must trust before running an `irm | iex` installer. This is the scene that replaces reading three docs.

**D4: deploy the visualizer to GitHub Pages** via a workflow, so the demo is a link rather than a clone plus a local HTTP server. The renderer already loads Three.js from CDN with an import map and needs no build step; the only reason it isn't already a URL is that nobody published it. Link it from the top of the README, above the fold.

**D5: add `.claude/skills/scene-author/SKILL.md`** so Claude Code has the contract in context: the schema, layout conventions (`pos` grids that don't overlap, left-to-right flow direction, `type` vocabulary), caption style rules for beginners (second person, one idea per hop, no unexplained jargon), and the instruction to run `Test-Scene.ps1` before declaring done. The agent's job becomes "write a scene and make the validator pass", a loop it can actually close.

**Rejected: post-processing effects** (bloom, scanlines, chromatic aberration) to chase the sci-fi look. They pull in `EffectComposer` and passes, breaking the single-file no-build property that makes this tool trivially runnable, and the dark-scene node graph with glowing latency-coloured trails already reads as sci-fi. Revisit only if the Pages deploy makes a build step acceptable.

**Rejected: generating a video.** A rendered mp4 cannot be inspected, filtered, or regenerated from live audit logs, and the repo already carries a 5.5 MB `brag.mp4` that GitHub will not play inline, as the README says itself. Interactive scenes strictly dominate.

## Consequences

**Positive**
- Claude Code's task changes from "invent a renderer" to "author JSON that passes a validator": bounded, verifiable, and improvable across attempts. This is the whole point of the ADR.
- The repo's most distinctive asset stops being buried. Architecture documentation becomes something a beginner watches in a browser tab in ninety seconds.
- Scenes stay honest: `Generate-LiveScene.ps1` already builds them from real audit logs, so the animated docs can be regenerated from what the platform actually did rather than what the diagram claims.
- Every future architecture change ships a scene diff, which is reviewable in a pull request like any other artifact.

**Negative**
- The schema becomes a public contract; renderer changes now need backwards compatibility or a version field. The `steps` extension is designed to be additive for exactly this reason.
- Guided mode adds UI state (pause, step index, next/prev) to a file that is currently a single render loop. Real complexity, contained to one file.
- Hand-written captions are the actual work and cannot be fully automated. A scene with accurate topology and vague narration teaches nothing. Budget writing time, not just generation time.
- GitHub Pages publishes the demo scenes publicly. `Generate-LiveScene.ps1` output is derived from local audit logs and may contain machine-specific model names and paths, so live scenes must stay gitignored and never be the deployed default.
