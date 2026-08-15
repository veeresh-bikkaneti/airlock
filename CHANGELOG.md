# Changelog

All notable changes to Airlock are recorded here, newest first. This file exists so anyone updating the platform can see what changed and why, in plain language — not just a commit list.

## Unreleased — planned, feature-based

Still pending, in order:

- **0.5.0 — Harness parity.** Download-progress for the HuggingFace import path (currently only `ollama pull` shows real progress — see `0.2.0` below). Re-verify opencode/Pi.dev/jcode/Copilot CLI/Gemini CLI now that the platform-level bugs they were blamed for are fixed, and file real PBIs only for confirmed defects. Not started.
- **0.6.0 — 3D visualizer, passes 2 and 3.** "Visual grandeur" and "interactivity/UX," per the visualizer's own sequenced roadmap (`docs/superpowers/plans/2026-08-07-3d-visualizer-data-depth-plan.md`) — pass 1 (data depth) shipped in `0.2.0`. No spec written yet for passes 2/3, so not started.

Housekeeping, no version bump: resolve the `headroom.EXE` install-state discrepancy (said uninstalled, binary still on disk — unresolved), review the remaining `docs/bugs/` files for redundancy against the ADRs/CHANGELOG that now supersede parts of them.

## Interactive user manual — 2026-08-15

- **Added `tools/airlock-manual/index.html`** — a self-contained, illustrated companion to the README, in the same standalone single-file pattern as `tools/3d-system-visualizer/`. No build step, no server: open it directly in a browser. Covers plain-English definitions for readers new to CLIs entirely, an animated CSS-3D architecture diagram, every `ai-*` command with a runnable snippet and a real use case, and a deep dive into the memory service's RAG pipeline (an animated request-flow diagram with the real vLLM degraded-path branch, a swimlane across every component, and an ER diagram of the two separate, unjoined stores it actually uses). Every animated control and the glossary flip-cards were exercised in a real headless browser (`browse`, DOM-state assertions on status text and token position, not just a visual read) before this landed. Linked from `README.md` and `docs/00-Artifact-Index.md`.

## 0.3.0 / 0.4.0 — 2026-08-13

- **Task router & cloud-limit handoff policy.** `ai-route`: a one-line, explainable answer to "should this task go local or cloud" before you find out the hard way — advisory only, never auto-switches anything. `ai-handoff` extends the existing session-resume snapshot (ADR-004) with the route decision, without touching its canonical fields. See [`ADR-006`](docs/adr/ADR-006-task-router-and-handoff-policy.md).
- **Memory retrieval governance.** Closes the "stale context treated as fact" gap in `memory-service`: config-driven `MemoryStore` (no more hardcoded defaults), freshness tracking on every `remember()` (real commit SHA + timestamp), retrieval that fails closed instead of silently degrading when nothing relevant is found, and `langchain-core`/`langsmith` pinned with tracing forced off at startup. See [`ADR-007`](docs/adr/ADR-007-memory-service-retrieval-governance.md).
- **Fixed same day:** `ai-claude-on` now calls `ai-handoff` automatically after a successful redirect — found while explaining the cloud-limit-switch flow to a user; the two commands shipped independent of each other, so switching to local never logged why. See ADR-006's "Known gap" section for the full writeup.

Both independently reviewed (fresh venv/test runs, not just a code read) before merging — see the ADRs for what was actually verified.

## 0.2.0 — 2026-08-12

Started by a real incident: a leftover setting pointed Claude Code at a dead local address and broke it for two hours, with a misleading "firewall or proxy" error. Everything below either closes that specific hole or fixes bugs found while testing the fix against this exact machine.

### Fixed

- **Claude Code could break — sometimes for good, sometimes for hours — because of a setting that never got cleaned up.** Added `ai-claude-on` / `ai-claude-off`: point Claude Code at your local model for one terminal window only, checked as actually alive before it's set, gone the moment you're done. No more editing a permanent settings file that outlives the platform.
- **Added `ai-doctor`** — one command that checks every place a "point this tool at localhost" setting can hide (any environment-variable scope, plus your Claude Code settings files) and prints the exact fix for anything it finds dead. This is what would have turned the original two-hour incident into a thirty-second one.
- **Picking a model that was too big for your graphics card.** Model auto-selection now checks your GPU's free memory, not just your system's total RAM — so it stops picking a model that technically "fits" but actually runs painfully slow because it spills onto the CPU. If a model you've already downloaded fits just as well as one you haven't, the already-downloaded one wins, so you're not stuck waiting on an avoidable download.
- **`ai-code` (the aider shortcut) silently using your real OpenAI account instead of your local model.** It now checks the model is actually installed and the local endpoint is actually responding before launching aider, and makes sure aider can't be tricked into using a different endpoint by a leftover setting elsewhere in your terminal.
- **vLLM failures wasted two minutes with one unhelpful error line.** Failures now say *why* (out of GPU memory, image not downloaded yet, container crashed) and show the real log lines. Airlock also remembers a vLLM failure so the next run skips straight to Ollama instead of repeating the same two-minute wait — use `-Backend vllm` when you're ready to try vLLM again.
- **The "Workflows" panel in the 3D visualizer** was an unlabeled wall of buttons. Each run now shows a color-coded status (worked / warning / failed) and which backend it used, capped to a scrollable list instead of growing forever.

### Added

- `ai-start -Backend <ollama|vllm>` to explicitly pick (and remember) your backend, instead of only ever being asked once on first run.
- `ai-code -Model <name>` to launch aider against a specific model instead of whatever's currently active.
- `ai-port` now shows progress on any model still downloading in the background, instead of pointing you at a raw log file.

### Docs

- The Quickstart Playbook, README, and component overview now describe the fixes above — they previously still described the old, buggy behavior (e.g. "sizes against system RAM," no mention of `ai-doctor`).

---

## 0.1.0 and earlier

Initial platform: one-command install, automatic Ollama setup, hardware-aware model picking, provider fallback (local-first, optional cloud), audit logging, and the original agent-CLI integrations (aider, Claude Code, Codex, Pi.dev, opencode, jcode). See `docs/00-Artifact-Index.md` for the original design docs.
