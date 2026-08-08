# 3D System Visualizer — Data Depth Pass

**Branch:** `feature/3d-visualizer-majestic-pass`
**Status:** approved, pending implementation

## Context

`tools/3d-system-visualizer/index.html` is a single-file, no-build Three.js
scene that renders a system's services/data stores/edges as a 3D node graph
with animated workflow playback. It just finished a visual-quality pass (PBR
materials, image-based lighting, selective bloom, real shadows, camera
fly-to-fit). This is the first of three sequenced follow-on passes toward a
"majestic" visualizer: **data depth** (this doc) → visual grandeur →
interactivity/UX. Each pass gets its own branch and spec.

The tool currently has one hardcoded scene: a `SCENE_DATA` constant baked
into `index.html` (11 nodes, 12 edges, 3 flows, schema `{nodes, edges,
flows}` with `node = {id, label, pos, type?}`). There is no way to view any
graph other than that one without editing the file.

## Goal

Let the visualizer load scene data from outside the file, and let a node/edge
carry enough metadata to answer "what is this and is it healthy" without
reading source. Concretely:

1. External scene loading — via a manifest-backed dropdown, a `?scene=`
   URL param, and a local-file upload.
2. Richer, ops-flavored node/edge metadata, surfaced through a click-to-inspect
   panel.
3. A visual status overlay (glow tint) so a degraded/down node reads at a
   glance, not just on click.

## Non-goals

- A second demo scene isn't required — one manifest entry is enough to prove
  the loading path; more scenes can be dropped into `scenes/` later with zero
  code changes.
- No changes to flow/edge visuals beyond what status-tinting and the inspect
  panel require (that's the next pass's territory).
- No persistence of "which scene is loaded" across page reloads.

## Design

### 1. Scene loading & switching

The current inline sequence — build `SCENE_DATA` → `buildNodes()` →
`buildEdges()` → wire up flow buttons/error panel — becomes a
`loadAndRenderScene(data)` function, callable more than once. A paired
`teardownScene()` disposes the previous scene's meshes/geometries/materials/
label sprites, stops any running `FlowAnimator`s, and clears the error and
flow-button panels. Teardown only runs *after* a new scene has fetched,
parsed, and passed `validateScene()` successfully — a bad load leaves the
current scene on screen instead of blanking it.

Three entry points feed `loadAndRenderScene`:

- **Manifest dropdown** — fetch `scenes/manifest.json`
  (`[{name, file}, ...]`), populate a `<select>` in the UI panel, fetch the
  chosen scene file on change.
- **URL query param** — `?scene=scenes/foo.json` on page load preselects
  that entry; falls back to the manifest's first entry if the param is
  absent, unset, or the fetch fails.
- **File upload** — a "Load file…" button plus a hidden
  `<input type="file" accept="application/json">`; read via
  `FileReader.readAsText`, `JSON.parse`, then the same `validateScene()` path
  as a fetched scene.

The current demo graph is extracted verbatim into
`scenes/ecommerce-demo.json` (schema unchanged) and becomes the manifest's
first/default entry, so opening the page with no query param behaves exactly
as it does today.

### 2. Metadata schema & inspect panel

Optional new fields, all backward compatible (absent = no behavior change):

- Node: `description` (string), `owner` (string), `status`
  (`"healthy" | "degraded" | "down"`, default `"healthy"`).
- Edge: `protocol` (string), `latencyMs` (number).

The existing `pointermove` raycaster only tests edge meshes today. Add a
`pointerdown`/click handler that raycasts against both `registry.nodes`
meshes and `registry.edges` meshes/arrows. A hit opens an "Inspect" panel
(new panel, bottom-left, same visual style as the existing panels) rendering
whichever fields are present on that node or edge. Clicking empty canvas or
the panel's close control clears it.

### 3. Status visual overlay

Node material keeps its existing type-driven base color (`TYPE_COLOR`);
`status` layers an emissive tint on top, using the same
clock-driven-sine-pulse technique already used for edge hover:

- `healthy` (default) — no tint, current appearance unchanged.
- `degraded` — slow amber emissive pulse, dimmer/slower than the edge-hover
  pulse so the two don't visually compete.
- `down` — red pulse, slightly higher intensity than degraded.

Computed in the existing render-loop `tick()`, alongside the current
per-frame edge-hover-pulse block. No new geometry (no halo/ring meshes) —
status reads as "this box glows wrong," not a decoration.

### 4. File layout

```
tools/3d-system-visualizer/
  index.html                    # gains loading/inspect/status logic; same location
  scenes/
    manifest.json                # [{ "name": "E-commerce order flow", "file": "ecommerce-demo.json" }]
    ecommerce-demo.json           # current SCENE_DATA, extracted verbatim
```

### 5. Validation & error handling

`validateScene()` is unchanged in behavior — it's called against whichever
data object was just loaded instead of only the module-level constant. Fetch
failures, JSON parse errors, and `FileReader` errors all route to the
existing red error panel (extended to show a load-failure message, not just
schema errors) rather than throwing to the console.

## Testing

Manual, since this is a no-build/no-test-framework single-file tool
(consistent with how the visual-quality pass before it was verified):

- Default load (no query param) renders `ecommerce-demo.json` identically to
  current behavior.
- `?scene=scenes/ecommerce-demo.json` explicitly selects the same scene.
- Switching scenes via the dropdown tears down and rebuilds cleanly (no
  leftover meshes, no duplicate flow buttons, previous flow's animator
  stopped).
- File upload of a valid scene JSON loads correctly; upload of malformed
  JSON shows the error panel without disturbing the currently-loaded scene.
- A node with `status: "degraded"` / `"down"` shows the pulse; a node with no
  `status` field looks identical to today.
- Clicking a node/edge opens the inspect panel with the right fields;
  clicking empty canvas clears it.
