---
name: scene-author
description: Author or edit animated architecture scenes for the airlock 3D system visualizer. Use whenever the request is to visualize, diagram, animate, or document a system, flow, architecture, or "how X works" for this repo — including phrasings like "make animated docs", "show me the architecture", "build a sci-fi visualization", or "explain this for beginners visually". Also use when editing any file under tools/3d-system-visualizer/scenes/.
---

# Authoring visualizer scenes

## Read this first: do not write animation code

The renderer already exists. `tools/3d-system-visualizer/index.html` is ~920 lines of Three.js that handles the camera, the 3D boxes, the glowing flow head with its fading trail, latency-based trail colour, node status glow, click-to-inspect panels, the scene picker, and error handling for malformed scenes.

**Your job is to write a JSON scene. Never write, modify, or regenerate the renderer** unless explicitly asked to change the renderer itself. Requests like "make an animated sci-fi visualization of the architecture" are requests for a **scene file**. The sci-fi look is already in the renderer; a well-shaped scene gets it for free.

This is the whole point of ADR-010: authoring JSON against a schema with a validator is a task you can verify. Inventing a renderer is not — you cannot see the output, so you cannot tell whether it worked.

## The loop you must close

1. Write or edit a scene at `tools/3d-system-visualizer/scenes/<name>.json`.
2. Run the validator. **This is not optional and it is the only evidence the scene works:**
   ```powershell
   .\scripts\Test-Scene.ps1 -Path tools/3d-system-visualizer/scenes/<name>.json
   ```
3. Fix every error. Fix warnings unless you can say why not.
4. Register the scene in `scenes/manifest.json` (`{ "name": "...", "file": "<name>.json" }`).
5. Re-run `.\scripts\Test-Scene.ps1` with no arguments so the whole manifest is checked.

Do not report the scene as done before the validator passes. "It looks right" is not a result here.

## Schema

Authoritative: `tools/3d-system-visualizer/scenes/schema.json`. Read it. Summary:

```json
{
  "title": "...", "description": "...",
  "nodes": [{ "id", "label", "pos": [x,y,z], "type", "description", "owner", "status" }],
  "edges": [{ "from", "to", "label", "protocol", "latencyMs" }],
  "flows": [{ "name", "path": ["a","b"], "steps": [...], "mode", "loop", "speed" }]
}
```

Rules the validator enforces, so get them right the first time:

- `id` is lowercase letters, digits, underscores. Unique.
- Every `edges[].from` and `.to` must name a real node.
- **Every consecutive pair in a flow `path` must have a matching edge.** Add the edge, or the animation jumps through empty space.
- **A `path` of N nodes has N−1 hops, so `steps` must have exactly N−1 entries.** This is the most common mistake — count hops, not nodes.
- No two nodes may share the same `pos`.
- `type` ∈ `service | datastore | infra | external | user`; `status` ∈ `healthy | degraded | down`; `mode` ∈ `auto | guided`.

## Layout conventions

`pos` is `[x, y, z]` in scene units and there is no auto-layout — you are the layout engine.

- **x** increases left-to-right along the main flow. Start the entry point around `-12` and step by 4.
- **y** stacks layers: `0` for the primary path, `+3` for supporting services, `-3` for datastores.
- **z** separates parallel branches: `0` for the spine, `±3` or `±4` for things off to the side.
- Keep any two nodes **at least 3 units apart** or the boxes visually collide.
- Keep `label` under 28 characters — longer text overflows the box face.
- Above roughly 20 nodes the graph stops being readable. Split into two scenes instead of cramming.

## Writing narration (`steps`)

Narration is what turns an animation into an explanation. A flow without it is a dot moving between boxes, which teaches a beginner nothing.

- Set `"mode": "guided"` and `"loop": false` on teaching flows. Captions only display in guided mode; the validator warns if you add steps without it.
- `caption`: one sentence, second person, present tense, under 90 characters. This is the line a beginner reads.
- `detail`: optional second line for the reader who wants the why. It must be safe to skip.
- One idea per hop. If a hop needs two ideas, it is two hops.
- No unexplained jargon. Write "your graphics card's memory", not "VRAM headroom", unless the previous caption defined it.
- Explain **why**, not just what. "One backend starts. Exactly one, always." lands; "Ollama process spawned" does not.
- Say the honest thing. If a step exists to prevent a specific failure, name the failure — that is the part people remember.

Compare, from `airlock-first-run.json`:

> **Good** — caption: "It picks a model that fits your graphics card." detail: "Sized against free VRAM, not free system RAM. A model that spills onto the CPU technically runs, but each turn takes minutes — which for an interactive loop is the same as broken."
>
> **Bad** — caption: "Model acquisition subsystem invoked." (What does the reader do with that?)

## Accuracy

Scenes are documentation. Everything in them is a factual claim about this repo.

- Derive topology from the actual scripts in `scripts/`, not from the README's prose or from memory.
- Do not invent `latencyMs`. Omit it unless you have a measurement — it colours the trail and implies precision you may not have.
- Use `status: "degraded"` or `"down"` only for a real, current problem. It glows amber or red and readers will believe it.
- For a scene about what really ran, prefer `scenes/Generate-LiveScene.ps1`, which builds one from the platform's own audit log. Hand-authored scenes describe design; generated scenes describe history. Do not blur them.
- Live scenes may contain machine-specific paths and model names. Keep them gitignored; never make one the deployed default.

## Existing scenes

- `airlock-first-run.json` — the beginner onboarding scene; guided narration of `ai-start`. Best template for a teaching scene.
- `ecommerce-demo.json` — generic demo, auto-looping flows, no narration. Best template for a plain topology scene.
- `local-ai-platform-live.json` — generated from audit logs; carries generator-only `provider` and `outcome` fields on flows. Do not hand-edit.
