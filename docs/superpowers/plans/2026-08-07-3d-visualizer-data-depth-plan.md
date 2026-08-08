# 3D Visualizer Data-Depth Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `tools/3d-system-visualizer/index.html` load scene data from outside the file (manifest dropdown, `?scene=` URL param, file upload), carry ops-flavored metadata on nodes/edges, and show node status as a visual glow — instead of one hardcoded scene baked into the HTML.

**Architecture:** Refactor the current "build once at module load" script into a reusable `loadAndRenderScene(data)` / `teardownScene()` pair, callable more than once. Three UI entry points (dropdown, URL param, file input) all funnel into the same pair. Metadata is optional-field passthrough on the existing node/edge schema, surfaced via a new click-to-inspect panel. Status is an emissive-pulse tint on the existing node material, reusing the pulse technique already used for edge hover.

**Tech Stack:** Vanilla ES modules, Three.js r0.185 via CDN import map (unchanged) — no build step, no test framework. Verification is manual: run a local static server and check behavior in a browser.

## Global Constraints

- No build step, no npm dependency additions — everything loads via the existing CDN import map in `index.html`.
- All new node/edge fields (`description`, `owner`, `status`, `protocol`, `latencyMs`) are optional; a scene omitting them must render identically to today.
- Default page load (no `?scene=` param) must behave exactly as it does today, sourced from `scenes/ecommerce-demo.json` instead of the inline `SCENE_DATA` constant.
- Teardown of a previous scene only happens after the new one fetches, parses, and passes `validateScene()` — a bad load must not blank the screen.
- File: `tools/3d-system-visualizer/index.html`. New dir: `tools/3d-system-visualizer/scenes/`.

---

### Task 1: Extract scene data, make scene load/teardown reusable

**Files:**
- Create: `tools/3d-system-visualizer/scenes/ecommerce-demo.json`
- Create: `tools/3d-system-visualizer/scenes/manifest.json`
- Modify: `tools/3d-system-visualizer/index.html:65-123` (remove `SCENE_DATA` const + its comment block)
- Modify: `tools/3d-system-visualizer/index.html:428-429` (remove direct `buildNodes(SCENE_DATA); buildEdges(SCENE_DATA);` calls)
- Modify: `tools/3d-system-visualizer/index.html:468-526` (add `dispose()` to `FlowAnimator`)
- Modify: `tools/3d-system-visualizer/index.html:556-606` (replace the one-shot "VALIDATION RESULTS -> UI" block with reusable functions + a `boot()` call)

**Interfaces:**
- Produces: `async function fetchScene(url) -> Promise<SceneData>`, `async function loadAndRenderScene(data: SceneData) -> Promise<void>`, `function teardownScene() -> void`, `async function switchScene(data: SceneData) -> Promise<void>` (tears down then loads) — later tasks call `fetchScene` and `switchScene`.
- Consumes: existing `buildNodes(data)`, `buildEdges(data)`, `validateScene(data)`, `registry`, `FlowAnimator`, `flyToDefault()`, `scheduleIdleAutoRotate()` — all unchanged signatures.

- [ ] **Step 1: Extract the demo scene to JSON**

Create `tools/3d-system-visualizer/scenes/ecommerce-demo.json` with exactly the current `SCENE_DATA` object as JSON (drop the JS comment block, keep the data verbatim):

```json
{
  "nodes": [
    { "id": "client",      "label": "Client",           "pos": [-8, 0, 0],  "type": "external" },
    { "id": "gateway",     "label": "API Gateway",       "pos": [-4, 0, 0],  "type": "service" },
    { "id": "auth",        "label": "Auth Service",      "pos": [-4, 3, -3], "type": "service" },
    { "id": "orders",      "label": "Orders Service",    "pos": [0, 0, 0],   "type": "service" },
    { "id": "inventory",   "label": "Inventory Service", "pos": [0, 3, -3],  "type": "service" },
    { "id": "payments",    "label": "Payments Service",  "pos": [4, 0, 0],   "type": "service" },
    { "id": "ledger_db",   "label": "Ledger DB",         "pos": [4, -3, -3],"type": "datastore" },
    { "id": "orders_db",   "label": "Orders DB",         "pos": [0, -3, -3],"type": "datastore" },
    { "id": "queue",       "label": "Event Queue",       "pos": [0, 0, 4],   "type": "infra" },
    { "id": "notifier",    "label": "Notification Svc",  "pos": [4, 3, 4],   "type": "service" },
    { "id": "webhook",     "label": "Partner Webhook",   "pos": [8, 3, 4],   "type": "external" }
  ],
  "edges": [
    { "from": "client",    "to": "gateway",   "label": "HTTPS" },
    { "from": "gateway",   "to": "auth",      "label": "verify token" },
    { "from": "auth",      "to": "gateway",   "label": "token ok" },
    { "from": "gateway",   "to": "orders",    "label": "create order" },
    { "from": "orders",    "to": "inventory", "label": "reserve stock" },
    { "from": "inventory", "to": "orders",    "label": "reserved" },
    { "from": "orders",    "to": "orders_db", "label": "write" },
    { "from": "orders",    "to": "payments",  "label": "charge" },
    { "from": "payments",  "to": "ledger_db", "label": "write" },
    { "from": "orders",    "to": "queue",     "label": "OrderCreated" },
    { "from": "queue",     "to": "notifier",  "label": "consume" },
    { "from": "notifier",  "to": "webhook",   "label": "POST" }
  ],
  "flows": [
    {
      "name": "Place order (happy path)",
      "path": ["client", "gateway", "auth", "gateway", "orders", "inventory", "orders", "payments", "ledger_db"],
      "loop": true,
      "speed": 3
    },
    {
      "name": "Order confirmation event",
      "path": ["orders", "queue", "notifier", "webhook"],
      "loop": true,
      "speed": 2.5
    },
    {
      "name": "BROKEN — missing edge (demonstrates error handling, see E)",
      "path": ["client", "payments"],
      "loop": false,
      "speed": 3
    }
  ]
}
```

- [ ] **Step 2: Create the manifest**

Create `tools/3d-system-visualizer/scenes/manifest.json`:

```json
[
  { "name": "E-commerce order flow", "file": "ecommerce-demo.json" }
]
```

- [ ] **Step 3: Remove the inline `SCENE_DATA` constant**

In `index.html`, delete the comment block and `const SCENE_DATA = { ... };` currently at lines 65-123 in full. Replace with two path constants used by this task and later ones:

```js
const MANIFEST_PATH = "scenes/manifest.json";
const DEFAULT_SCENE_PATH = "scenes/ecommerce-demo.json";
```

- [ ] **Step 4: Add `dispose()` to `FlowAnimator`**

In the `FlowAnimator` class (currently lines 468-526), add a method alongside `start()`/`stop()`/`update()`:

```js
  dispose() {
    this.stop();
    scene.remove(this.dot);
    this.dot.geometry.dispose();
    this.dot.material.dispose();
  }
```

- [ ] **Step 5: Replace the one-shot setup block with reusable functions**

Delete the current lines 428-429 (`buildNodes(SCENE_DATA); buildEdges(SCENE_DATA);`) and the current lines 556-606 (from the `VALIDATION RESULTS -> UI` comment through the end of the flow-button-building `for` loop and the `labels-toggle` listener registration — keep the `labels-toggle` listener, it's unchanged and stays where it is, just after this new block). In their place:

```js
/* ======================================================================
   SCENE LOADING — reusable across the initial boot, the manifest
   dropdown, the ?scene= URL param, and file upload (added in later
   tasks). teardownScene() is safe to call on an empty registry, so
   switchScene() always tears down then loads, uniformly.
   ====================================================================== */
const errorPanel = document.getElementById("errors");
const errorList = document.getElementById("error-list");
const flowButtonsHost = document.getElementById("flow-buttons");
const animators = new Map();

async function fetchScene(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} loading ${url}`);
  return res.json();
}

function teardownScene() {
  for (const { mesh, label } of registry.nodes.values()) {
    scene.remove(mesh, label);
    mesh.geometry.dispose();
    mesh.material.dispose();
    label.material.map.dispose();
    label.material.dispose();
  }
  for (const { mesh, arrow } of registry.edges.values()) {
    scene.remove(mesh, arrow);
    mesh.geometry.dispose();
    mesh.material.dispose();
    arrow.geometry.dispose();
    arrow.material.dispose();
  }
  for (const animator of animators.values()) animator.dispose();
  animators.clear();
  registry.nodes.clear();
  registry.edges.clear();
  registry.edgeMeshes.length = 0;
  hoveredEdgeKey = null;
  errorPanel.style.display = "none";
  errorList.innerHTML = "";
  flowButtonsHost.innerHTML = "";
}

async function loadAndRenderScene(data) {
  const { errors: edgeErrors, flowErrors } = validateScene(data);

  buildNodes(data);
  buildEdges(data);

  const allErrors = [
    ...edgeErrors.map(e => e.message),
    ...[...flowErrors.entries()].flatMap(([name, msgs]) => msgs.map(m => `"${name}": ${m}`))
  ];
  if (allErrors.length) {
    errorPanel.style.display = "block";
    for (const msg of allErrors) {
      const li = document.createElement("li");
      li.textContent = msg;
      errorList.appendChild(li);
    }
  }

  for (const flow of data.flows) {
    const btn = document.createElement("button");
    const broken = flowErrors.has(flow.name);
    btn.textContent = broken ? `⚠ ${flow.name}` : `▶ ${flow.name}`;
    btn.disabled = broken;
    flowButtonsHost.appendChild(btn);

    if (!broken) {
      const animator = new FlowAnimator(flow, registry.edges);
      animators.set(flow.name, animator);
      btn.addEventListener("click", () => {
        if (animator.playing) {
          animator.stop();
          btn.classList.remove("playing");
          btn.textContent = `▶ ${flow.name}`;
          flyToDefault();
        } else {
          animator.start();
          btn.classList.add("playing");
          btn.textContent = `⏸ ${flow.name}`;
          flyToFlow(flow);
          scheduleIdleAutoRotate();
        }
      });
    }
  }

  flyToDefault();
  scheduleIdleAutoRotate();
}

async function switchScene(data) {
  teardownScene();
  await loadAndRenderScene(data);
}

async function boot() {
  const data = await fetchScene(DEFAULT_SCENE_PATH);
  await switchScene(data);
}
boot();

document.getElementById("labels-toggle").addEventListener("change", (ev) => {
  for (const { label } of registry.nodes.values()) label.visible = ev.target.checked;
});
```

Note `flyToFlow`, `flyToDefault`, `scheduleIdleAutoRotate`, `registry`, `hoveredEdgeKey`, `buildNodes`, `buildEdges`, `validateScene`, `BLOOM_LAYER` are all defined earlier in the file and untouched by this task.

- [ ] **Step 6: Verify manually**

```powershell
python -m http.server 8347 --directory tools/3d-system-visualizer
```

Open `http://localhost:8347`. Expected: identical to current behavior — same 11-node scene, same 3 flow buttons, same "BROKEN" error in the red panel, workflows still play. Open devtools console: no errors.

- [ ] **Step 7: Commit**

```bash
git add tools/3d-system-visualizer/index.html tools/3d-system-visualizer/scenes/
git commit -m "refactor(3d-visualizer): load scene data from JSON, make load/teardown reusable"
```

---

### Task 2: Manifest dropdown + `?scene=` URL param

**Files:**
- Modify: `tools/3d-system-visualizer/index.html` (UI panel markup, CSS, `boot()`)

**Interfaces:**
- Consumes: `fetchScene(url)`, `switchScene(data)`, `MANIFEST_PATH`, `DEFAULT_SCENE_PATH` from Task 1.
- Produces: nothing new consumed by later tasks.

- [ ] **Step 1: Add the dropdown markup**

In the `#ui` panel (inside the "Workflows" `.panel` div, current lines 31-35), add a scene-select control above the flow buttons:

```html
    <div class="panel">
      <h3>Scene</h3>
      <select id="scene-select"></select>
    </div>
    <div class="panel">
      <h3>Workflows</h3>
      <div id="flow-buttons"></div>
      <label><input type="checkbox" id="labels-toggle" checked /> Show labels</label>
    </div>
```

- [ ] **Step 2: Style the select**

In the `<style>` block, add next to the existing `#ui button` rule:

```css
  #ui select { display: block; width: 100%; margin-bottom: 6px; padding: 7px 10px; background: #1c2128; border: 1px solid #333a44; color: #e6e9ee; border-radius: 6px; font-size: 13px; }
```

- [ ] **Step 3: Populate the dropdown and wire it to `switchScene`, add `?scene=` param handling**

Replace the `boot()` function from Task 1 with:

```js
function currentSceneParam() {
  return new URLSearchParams(window.location.search).get("scene");
}

async function boot() {
  const manifest = await fetchScene(MANIFEST_PATH);
  const sceneSelect = document.getElementById("scene-select");
  for (const entry of manifest) {
    const opt = document.createElement("option");
    opt.value = `scenes/${entry.file}`;
    opt.textContent = entry.name;
    sceneSelect.appendChild(opt);
  }

  const requested = currentSceneParam();
  const initialPath = manifest.some(e => `scenes/${e.file}` === requested)
    ? requested
    : (sceneSelect.options[0]?.value ?? DEFAULT_SCENE_PATH);
  sceneSelect.value = initialPath;

  sceneSelect.addEventListener("change", async () => {
    try {
      const data = await fetchScene(sceneSelect.value);
      await switchScene(data);
    } catch (err) {
      errorPanel.style.display = "block";
      const li = document.createElement("li");
      li.textContent = `Failed to load "${sceneSelect.value}": ${err.message}`;
      errorList.appendChild(li);
    }
  });

  const data = await fetchScene(initialPath);
  await switchScene(data);
}
boot();
```

- [ ] **Step 4: Verify manually**

Reload `http://localhost:8347` — dropdown shows "E-commerce order flow", scene loads same as before. Try `http://localhost:8347/?scene=scenes/ecommerce-demo.json` — same result. Try `http://localhost:8347/?scene=scenes/does-not-exist.json` — falls back to the manifest's first entry (dropdown still shows "E-commerce order flow", scene loads normally, no console error since the invalid param is simply not matched).

- [ ] **Step 5: Commit**

```bash
git add tools/3d-system-visualizer/index.html
git commit -m "feat(3d-visualizer): manifest-backed scene dropdown and ?scene= URL param"
```

---

### Task 3: File upload entry point

**Files:**
- Modify: `tools/3d-system-visualizer/index.html` (UI markup, `boot()` area)

**Interfaces:**
- Consumes: `switchScene(data)`, `errorPanel`, `errorList` from Task 1.

- [ ] **Step 1: Add the upload control**

In the "Scene" panel added in Task 2, add below the `<select>`:

```html
    <div class="panel">
      <h3>Scene</h3>
      <select id="scene-select"></select>
      <button id="scene-upload-btn" type="button">Load file…</button>
      <input id="scene-upload-input" type="file" accept="application/json" style="display:none" />
    </div>
```

- [ ] **Step 2: Wire the upload button to `switchScene`**

After the `sceneSelect.addEventListener("change", ...)` block added in Task 2 (still inside `boot()`), add:

```js
  const uploadBtn = document.getElementById("scene-upload-btn");
  const uploadInput = document.getElementById("scene-upload-input");
  uploadBtn.addEventListener("click", () => uploadInput.click());
  uploadInput.addEventListener("change", async () => {
    const file = uploadInput.files[0];
    uploadInput.value = ""; // allow re-selecting the same file later
    if (!file) return;
    try {
      const text = await file.text();
      const data = JSON.parse(text);
      await switchScene(data);
      sceneSelect.value = ""; // no manifest entry matches an uploaded file
    } catch (err) {
      errorPanel.style.display = "block";
      const li = document.createElement("li");
      li.textContent = `Failed to load "${file.name}": ${err.message}`;
      errorList.appendChild(li);
    }
  });
```

- [ ] **Step 3: Verify manually**

Save a copy of `scenes/ecommerce-demo.json` outside the repo as `test-scene.json`, edit one node's `label`. In the browser, click "Load file…", pick it — scene reloads showing the edited label, dropdown selection clears. Then pick a file containing invalid JSON (e.g. `{not valid`) — error panel shows a "Failed to load" message, previous scene stays on screen and interactive (this is the manual proof of the "teardown only after successful validate" rule from the spec).

- [ ] **Step 4: Commit**

```bash
git add tools/3d-system-visualizer/index.html
git commit -m "feat(3d-visualizer): load scene from local file upload"
```

---

### Task 4: Node/edge metadata schema + click-to-inspect panel

**Files:**
- Modify: `tools/3d-system-visualizer/index.html` (markup, CSS, raycasting, new click handler)

**Interfaces:**
- Consumes: `registry.nodes`, `registry.edges`, `camera`, `renderer.domElement`, existing `raycaster`/`pointerNdc` from the hover-highlight code (lines ~436-459).
- Produces: nothing consumed by later tasks — Task 5 (status overlay) reads `n.data.status` directly from scene data, not from this panel.

- [ ] **Step 1: Add the inspect panel markup**

After the `#errors` div (current lines 38-43), add a sibling panel, hidden by default:

```html
  <div id="inspect" style="display:none">
    <div class="panel">
      <button id="inspect-close" type="button" aria-label="Close">×</button>
      <h3 id="inspect-title"></h3>
      <dl id="inspect-fields"></dl>
    </div>
  </div>
```

- [ ] **Step 2: Style it**

Add to the `<style>` block:

```css
  #inspect { position: fixed; bottom: 14px; left: 14px; z-index: 10; max-width: 320px; }
  #inspect .panel { position: relative; }
  #inspect-close { position: absolute; top: 6px; right: 8px; width: auto; background: none; border: none; color: #8b93a1; font-size: 16px; cursor: pointer; padding: 0; margin: 0; }
  #inspect dl { margin: 0; font-size: 12.5px; }
  #inspect dt { color: #8b93a1; margin-top: 6px; }
  #inspect dd { margin: 0; color: #d8dbe0; }
```

- [ ] **Step 3: Extend node/edge data with optional metadata**

No code change here — this documents the schema addition consumed by Steps 4-5 and by Task 5. `SceneData` nodes may now carry `description?: string`, `owner?: string`, `status?: "healthy" | "degraded" | "down"`. Edges may carry `protocol?: string`, `latencyMs?: number`. All optional; `buildNodes`/`buildEdges` from Task 1 already pass the full node/edge object into `registry`, so no change is needed there — the fields just ride along in `entry.data`.

- [ ] **Step 4: Add a click handler that raycasts nodes and edges**

After the existing `pointermove` listener (ends around line 459 in the original file — the block that sets `hoveredEdgeKey`), add:

```js
const inspectPanel = document.getElementById("inspect");
const inspectTitle = document.getElementById("inspect-title");
const inspectFields = document.getElementById("inspect-fields");
document.getElementById("inspect-close").addEventListener("click", () => {
  inspectPanel.style.display = "none";
});

function showInspect(title, fields) {
  inspectTitle.textContent = title;
  inspectFields.innerHTML = "";
  for (const [key, value] of fields) {
    if (value === undefined || value === null || value === "") continue;
    const dt = document.createElement("dt");
    dt.textContent = key;
    const dd = document.createElement("dd");
    dd.textContent = String(value);
    inspectFields.append(dt, dd);
  }
  inspectPanel.style.display = "block";
}

renderer.domElement.addEventListener("click", (ev) => {
  const rect = renderer.domElement.getBoundingClientRect();
  pointerNdc.x = ((ev.clientX - rect.left) / rect.width) * 2 - 1;
  pointerNdc.y = -((ev.clientY - rect.top) / rect.height) * 2 + 1;
  raycaster.setFromCamera(pointerNdc, camera);

  const nodeMeshes = [...registry.nodes.values()].map(n => n.mesh);
  const nodeHit = raycaster.intersectObjects(nodeMeshes, false)[0];
  if (nodeHit) {
    const entry = [...registry.nodes.values()].find(n => n.mesh === nodeHit.object);
    showInspect(entry.data.label, [
      ["Type", entry.data.type],
      ["Status", entry.data.status],
      ["Owner", entry.data.owner],
      ["Description", entry.data.description]
    ]);
    return;
  }

  const edgeHit = raycaster.intersectObjects(registry.edgeMeshes, false)[0];
  if (edgeHit) {
    const entry = [...registry.edges.values()].find(e => e.mesh === edgeHit.object || e.arrow === edgeHit.object);
    showInspect(entry.data.label ?? `${entry.data.from} → ${entry.data.to}`, [
      ["From", entry.data.from],
      ["To", entry.data.to],
      ["Protocol", entry.data.protocol],
      ["Latency", entry.data.latencyMs !== undefined ? `${entry.data.latencyMs} ms` : undefined]
    ]);
    return;
  }

  inspectPanel.style.display = "none";
});
```

- [ ] **Step 5: Verify manually**

Click a node box — inspect panel appears bottom-left with its label as title and Type filled in (Status/Owner/Description blank since the shipped scene has none yet — added in Task 6). Click an edge cylinder or arrowhead — panel shows From/To. Click empty canvas — panel closes. Click the × — panel closes.

- [ ] **Step 6: Commit**

```bash
git add tools/3d-system-visualizer/index.html
git commit -m "feat(3d-visualizer): click-to-inspect panel for node/edge metadata"
```

---

### Task 5: Status visual overlay

**Files:**
- Modify: `tools/3d-system-visualizer/index.html` (render loop `tick()`)

**Interfaces:**
- Consumes: `registry.nodes` (each entry's `data.status`, `mesh.material.emissive`), `clock` — all from existing code.

- [ ] **Step 1: Add the status pulse to the render loop**

In `tick()` (current lines 631-655), alongside the existing edge-hover-pulse block (`if (hoveredEdgeKey) { ... }`), add a status pulse loop right after it:

```js
  for (const { data, mesh } of registry.nodes.values()) {
    if (data.status === "degraded") {
      const pulse = 0.4 + Math.sin(t * 2.5) * 0.25;
      mesh.material.emissive.setRGB(0.55 * pulse, 0.4 * pulse, 0.0);
    } else if (data.status === "down") {
      const pulse = 0.5 + Math.sin(t * 4) * 0.3;
      mesh.material.emissive.setRGB(0.85 * pulse, 0.05 * pulse, 0.05 * pulse);
    } else if (mesh.material.emissive.getHex() !== 0x000000) {
      mesh.material.emissive.setHex(0x000000); // scene switched to a healthy node reusing this material instance's prior tint
    }
  }
```

Place this before `scene.traverse(darkenNonBloomed);` so the tinted emissive is what both the bloom pass and the final composite see.

- [ ] **Step 2: Verify manually**

Won't be visible until Task 6 adds `status` to the shipped scene — defer visual confirmation to Task 6's verification step. For now just confirm no console errors and the scene still renders/plays normally (the `else if` branch is a no-op on every node since none has `status` set yet).

- [ ] **Step 3: Commit**

```bash
git add tools/3d-system-visualizer/index.html
git commit -m "feat(3d-visualizer): emissive pulse overlay for degraded/down node status"
```

---

### Task 6: Demonstrate metadata + status in the shipped scene, full regression pass

**Files:**
- Modify: `tools/3d-system-visualizer/scenes/ecommerce-demo.json`

**Interfaces:**
- None — this is data only, exercising Tasks 4 and 5 end-to-end without any custom upload.

- [ ] **Step 1: Add example metadata to a few nodes and edges**

Edit `scenes/ecommerce-demo.json`: add `description`/`owner`/`status` to a handful of nodes, and `protocol`/`latencyMs` to a handful of edges. Example (merge into the existing node/edge objects, don't duplicate them):

```json
{ "id": "payments", "label": "Payments Service", "pos": [4, 0, 0], "type": "service",
  "description": "Charges cards via the processor and writes to the ledger.",
  "owner": "payments-team", "status": "degraded" },
```

```json
{ "id": "ledger_db", "label": "Ledger DB", "pos": [4, -3, -3], "type": "datastore",
  "description": "Append-only financial ledger.", "owner": "payments-team", "status": "down" },
```

```json
{ "from": "orders", "to": "payments", "label": "charge", "protocol": "gRPC", "latencyMs": 45 },
```

Leave the remaining nodes/edges as-is (no metadata) to also prove the "absent = unchanged" behavior in the same scene.

- [ ] **Step 2: Full manual regression pass**

Run the local server, reload with no query param, and walk the spec's testing checklist:

- Default load renders identically apart from the two new visual pulses (Payments amber, Ledger DB red) — everything else (camera, lighting, bloom, shadows) unchanged.
- `?scene=scenes/ecommerce-demo.json` gives the same result.
- Dropdown still shows one entry and reselecting doesn't break anything.
- Upload a hand-edited copy (from Task 3's manual test) — teardown/rebuild is clean: no leftover meshes, no duplicate flow buttons, no lingering pulse from the previous scene's `payments`/`ledger_db` nodes if the uploaded copy removes their `status` field.
- Upload malformed JSON — error panel shows the failure, current scene keeps working.
- Click the Payments node — inspect panel shows Type, Status "degraded", Owner "payments-team", Description text.
- Click the `orders → payments` edge — inspect panel shows Protocol "gRPC", Latency "45 ms".
- Click empty canvas — panel closes.
- All three workflow buttons still play correctly, camera fly-to-fit still works, idle auto-rotate still kicks in after a few seconds of inactivity.

- [ ] **Step 3: Commit**

```bash
git add tools/3d-system-visualizer/scenes/ecommerce-demo.json
git commit -m "feat(3d-visualizer): demonstrate metadata and status overlay in the shipped scene"
```

---

## After This Plan

Not part of this plan (handled after all tasks pass local verification):
1. Merge `feature/3d-visualizer-majestic-pass` into `main` per repo workflow (`git merge --no-ff` or `gh pr create` — never push straight to `main`).
2. Update the `/brag:brag` demo video to reflect the new data-loading/inspect/status features.
