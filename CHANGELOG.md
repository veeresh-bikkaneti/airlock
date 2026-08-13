# Changelog

All notable changes to Airlock are recorded here, newest first. This file exists so anyone updating the platform can see what changed and why, in plain language — not just a commit list.

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
