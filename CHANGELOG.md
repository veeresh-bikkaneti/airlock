# Changelog

All notable changes to Airlock are recorded here, newest first. This file exists so anyone updating the platform can see what changed and why, in plain language — not just a commit list.

## ADR-014: agent operating contract — the repo tells the truth — 2026-09-04

The files a coding agent reads first (`CLAUDE.md`, `AGENTS.md`) described a Ruflo/claude-flow swarm product (`npm run build && npm test`, Agent Booster, Darwin/Flywheel/MetaHarness). This repository is Airlock. User-facing tool-calling copy still sold the 2026-08-20 "pick a Tools-badged Ollama model; `qwen3-coder:30b` passed 3/3" line as the fix. That 3/3 was a single-call probe. Later live evidence (`docs/adr/evidence/AGENT-005-repair-loop-live-evidence.md`) is **0/6** on the repair-loop contract; `config/models.json` already called it "not solved."

- The portable contract is `AGENTS.md` (Grok, Copilot, Gemini, Antigravity, Cursor, Codex, OpenCode). `CLAUDE.md` is a Claude Code adapter (`@AGENTS.md`); `GEMINI.md` and `.github/copilot-instructions.md` are the same kind of pointer. Not a Claude-only repo.
- Replaced the Ruflo `CLAUDE.md` overlay with that contract: real test commands, known-failed local tool-calling ledger (do not retry), Ollama/vLLM are not a verified agentic runtime here, the one 3/3 pass lives on `feature/adr-013-pi-harness-verification` and is not enabled on this branch. Ruflo MCP stays in `.mcp.json` (`autoStart: false`); it is no longer the default story.
- Headroom RTK remains an optional appendix in `AGENTS.md`; it is not required.
- `config/opencode.json.template` default model is `ollama/qwen3-coder:30b` as a **connection/chat default**, not an agentic-ready default. It is no longer `devstral-small-2:24b`.
- README tool-calling section, `docs/08-Agent-CLI-Setup-Guide.md`, and `docs/05-Provider-Fallback-Matrix.md` aligned with that evidence. `supportsFunctionCalling` is described as a seed, not a reliability verdict.
- Machine-checked by `scripts/Test-AgentOperatingContract.ps1` (CI already runs every `scripts/Test-*.ps1`).
- Does **not** merge the Pi/Unsloth path, add `ai-agent-start`, or change `ai-start` model ranking. Those are AIR-015 / AIR-016.

The 2026-08-20 CHANGELOG entry below is historical and left in place. Do not read it as current agentic status.

## Correction: the tool-calling root cause below was wrong — it's model choice, not the OpenAI-compat layer — 2026-08-20

The two entries below (and the docs they shipped with, both already merged to main) blame "Ollama's OpenAI-compatible tool-calling layer" for the raw-JSON-leak failure, and prescribe a tool-call proxy as the fix. That's too broad and points at the wrong layer. Corrected `README.md`, `docs/08-Agent-CLI-Setup-Guide.md`, and `config/opencode.json.template` in this pass — this entry records why.

- **Re-tested `qwen2.5-coder:7b` against Ollama's *native* `/api/chat`, no OpenAI-compat translation involved at all, and got the identical failure.** Its chat template genuinely defines `<tool_call>` markup (`/api/show`) and `/api/tags` lists `"tools"` in its capabilities — the plumbing supports tool calls. The model's weights just aren't reliably trained to consistently emit that exact wrapper, so it falls back to printing its best-guess JSON as plain text. This isn't an Ollama compat-layer bug.
- **The real, live-verified fix: pick a model that's actually reliable at this before reaching for the proxy.** `qwen3-coder:30b` passed 3/3 clean on the same single-tool-call scenario `qwen2.5-coder:7b` failed 3/3 on, via direct `/api/chat` calls and via the real opencode CLI with no proxy in the loop. `ollama.com/library/<model>`'s "Tools" badge is a decent practical predictor (curated/editorial, not a technical guarantee) — `config/opencode.json.template`'s `baseURL` now points straight at Ollama again instead of forcing the proxy by default.
- **Also caught, live, mid-investigation: the port drifted again.** Airlock hadn't been started this session; Ollama was running on its raw default (`11434`), not via `ai-start`, and every config still said `12345` from days earlier. Fixed again. This is the same structural finding as the Pi.dev entry below, just recurring on schedule — not a regression in anything shipped since.
- **Open, unresolved caveat — don't read this as "solved":** a later full-session opencode test against `qwen3-coder:30b` (not the narrow single-tool-call test above) correctly executed a file read, then attempted an *unprompted* file-write using malformed, non-Hermes tool-call markup that opencode didn't recognize — it printed as text instead of executing (confirmed via `git status`, nothing was actually written). Single controlled tool calls: proven reliable. Multi-turn, full tool surface: not yet proven reliable, and this specific near-miss is why. The tool-call proxy (`ai-tool-proxy-start`, `tool-proxy/`) stays in the platform as an opt-in fallback for models without native tool support — it isn't wrong, it just isn't the primary fix.
- **Also flagged, not fixed:** `ai-start`'s own model auto-selection picks purely on GPU-memory fit, with zero awareness of tool-calling reliability — it defaulted to `qwen2.5-coder:7b` on a fresh run today. Real platform-level gap; needs a scoped decision before it's touched, not a unilateral rewrite.

## Pi.dev: same config-path drift, same tool-calling gap, plus a real-time recurrence — 2026-08-15

Follow-up to the opencode investigation below, prompted directly by the user: "you said we should use this with opencode, I faced the same problem with pi also." Tested Pi.dev with the same rigor — live commands, not doc re-reads.

- **Same bug class, independently confirmed.** `~/.pi/agent/models.json`'s `baseUrl` was pointed at port 11434; the live Ollama instance was on 12345. Fixed. `docs/08-Agent-CLI-Setup-Guide.md`'s Pi.dev section also had the provider key wrong (`ollama-local`, which nothing reads) — the real key, confirmed against both the live config and `config/pi-models.json.template` (which was already correct), is `ollama`.
- **It happened again, live, inside this same investigation.** After restarting Ollama for an unrelated vLLM test, the new instance landed on port 12345. `~/.opencode/opencode.json` — already fixed once earlier this session — was still pointed at 11434 from before the restart, so it was broken again by the time this investigation finished, and got re-fixed. This is the actual evidence for the structural claim below: the port isn't a one-time misconfiguration, it's a live value that drifts every time the backend restarts, and every tool that hardcodes it will drift with it. `Start-AI.ps1`'s port-scan-and-adopt behavior (`$portScanList = @(11434) + (12345..12350)`, silently adopting whatever's already running unless `-StrictPort` is passed) is the root cause; each tool's config file is a snapshot of one moment, not a live value.
- **Corrected a wrong finding from the first pass.** Initially reported Pi's `-p` mode as giving an "honest refusal" when asked to read a file without `@file`. Re-tested against advice to verify, using `--no-tools` as a control: the two runs gave *different* output, proving tools are wired and on by default in `-p` mode — and what actually happens is `qwen2.5-coder:7b` prints the tool call as raw JSON text (`{"name": "read", "arguments": {"path": "cv.md"}}`) instead of executing it. That's the identical failure shape already reproduced under opencode with the same model. Two independent harnesses, same local model, same symptom — confirms this is Ollama's OpenAI-compat tool-calling layer, not a bug in either CLI.
- **The generalizable fix, confirmed working on the same model that fails at autonomous tool use:** deterministic, harness-driven file attachment — `pi -p "@cv.md" "..."` and aider's `ai-code --file` — sidesteps the problem entirely by never asking the model to decide whether to call a tool. Tested live: clean, correct, specific answers both times. This is the real answer to "is there another solution" — not a bigger model, not a config fix, but not asking a small local model to make an autonomous tool-call decision in the first place.
- **`Start-VLLM.ps1` findings, documented not patched:** this repo's own vLLM launch path never actually turns tool-calling on (`--enable-auto-tool-choice --tool-call-parser hermes` — the correct parser for the Qwen2.5 family — are both absent from the `docker run` invocation), and it relies on vLLM's ~0.9 default `--gpu-memory-utilization`, which fails outright on a machine where the GPU also drives the display (`ValueError: Free memory ... less than desired ...`). Both are real, fixable gaps. Not patched this round: live testing hit a separate, deeper blocker — vLLM 0.26.0's V1 engine requires CUDA UVA (unified virtual addressing), which Docker Desktop's WSL2 GPU passthrough does not currently expose on this machine (`RuntimeError: UVA is not available`, reproduced with a bare-minimum launch with no extra flags, and confirmed `VLLM_USE_V1=0` is a no-op since V0 support was fully removed in 0.26.0). Shipping flag changes to a script that can't currently start on this machine isn't verifiable, so it isn't done here — the two real flag gaps and the UVA blocker are recorded as known gaps instead. A pinned older vLLM image (predating the V1-only engine transition) is a real next step if vLLM is worth pursuing further, not attempted in this pass.

## opencode setup guide: real config-path and tool-calling findings — 2026-08-15

A user reported opencode + Ollama "hallucinating and drifting," responding in raw XML/JSON tags, and being unable to use slash commands — forcing a fallback to cloud models. Investigated end-to-end against a real project (not this repo), not just re-read the docs.

- **`docs/08-Agent-CLI-Setup-Guide.md`'s opencode section was itself stale and wrong.** Re-verified live against the installed opencode 1.18.16 with `--print-logs --log-level DEBUG`: it never reads a bare `opencode.json` at repo root (what the doc said to create) — real paths are `<project>/.opencode/opencode.json` and `~/.opencode/opencode.json` (a different directory than `~/.config/opencode/`, which is also checked but loads first and gets silently overridden by the later files, not replaced). Doc rewritten with the real, tested paths and precedence order.
- **Real, live, currently-active misconfiguration found and fixed** (not in this repo — a separate project's environment): the user's actual global opencode config pointed at port 12345, but `Start-AI.ps1` had adopted an already-running Ollama on port 11434 (its own default — common when Ollama auto-starts as a background service). Every request failed with a connection error and retried on a backoff that looks like a hang from the terminal. Also found and fixed: the config's model allowlist named 3 models that were never actually pulled, and omitted the one 30B model that was.
- **Separately, reproduced a real tool-calling reliability gap in Ollama's OpenAI-compatible layer under opencode's agentic loop** — confirmed on both `qwen2.5-coder:7b` (emitted a raw tool-call as visible chat text with a hallucinated placeholder path) and `qwen3-coder:30b` (a malformed tool-call schema, followed by the model hallucinating a nonexistent tool and then fetching unrelated public web pages instead of the local file it was asked to read). This is not a config bug and no template fix solves it — documented plainly, matching the same Ollama compat-layer limitation already disclosed for the memory-service RAG path.

## Unreleased — planned, feature-based

Still pending, in order:

- **0.5.0 — Harness parity.** Download-progress for the HuggingFace import path (currently only `ollama pull` shows real progress — see `0.2.0` below). Re-verify opencode/Pi.dev/jcode/Copilot CLI/Gemini CLI now that the platform-level bugs they were blamed for are fixed, and file real PBIs only for confirmed defects. Not started.
- **0.6.0 — 3D visualizer, passes 2 and 3.** "Visual grandeur" and "interactivity/UX," per the visualizer's own sequenced roadmap (`docs/superpowers/plans/2026-08-07-3d-visualizer-data-depth-plan.md`) — pass 1 (data depth) shipped in `0.2.0`. No spec written yet for passes 2/3, so not started.

Housekeeping, no version bump: resolve the `headroom.EXE` install-state discrepancy (said uninstalled, binary still on disk — unresolved), review the remaining `docs/bugs/` files for redundancy against the ADRs/CHANGELOG that now supersede parts of them.

## Interactive user manual — 2026-08-15

- **Added `tools/airlock-manual/index.html`** — a self-contained, illustrated companion to the README, in the same standalone single-file pattern as `tools/3d-system-visualizer/`. No build step, no server: open it directly in a browser. Covers plain-English definitions for readers new to CLIs entirely, an animated CSS-3D architecture diagram, every `ai-*` command with a runnable snippet and a real use case, and a deep dive into the memory service's RAG pipeline (an animated request-flow diagram with the real vLLM degraded-path branch, a swimlane across every component, and an ER diagram of the two separate, unjoined stores it actually uses). Every animated control and the glossary flip-cards were exercised in a real headless browser (`browse`, DOM-state assertions on status text and token position, not just a visual read) before this landed. Linked from `README.md` and `docs/00-Artifact-Index.md`.

## Airlock hardening pass — 2026-08-14

A backlog review found four merged PRs (#4-#6, plus this pass) that had never made it into this file. Backfilled here rather than left silently undocumented.

- **`ai-claude-on` no longer risks a silent auth failure.** It sets `ANTHROPIC_AUTH_TOKEN` instead of `ANTHROPIC_API_KEY` — the variable Anthropic's own docs name for gateway/proxy routing, which outranks `API_KEY` in precedence and can't be shadowed by a previously-declined key sitting in an interactive Claude Code session. Swept the two docs (`README.md`, `docs/08-Agent-CLI-Setup-Guide.md`) that showed the old variable in the same gateway context; left the platform's own direct-cloud-fallback references alone, since those genuinely mean `ANTHROPIC_API_KEY`. See [`ADR-009`](docs/adr/ADR-009-multi-provider-claude-code-profiles.md).
- **Working tree no longer ships `brag.mp4`/the demo mp3** (12 MB → 3.7 MB) — replaced with a WebP preview in the README. `.git` itself is unchanged (history wasn't rewritten; that's a deliberate, still-open decision, not an oversight — see `docs/bugs-2/BACKLOG-airlock-hardening-and-adoption_updated.md`'s AIR-A13 for the actual numbers).
- **Added `ai-uninstall`** (`Uninstall-AI.ps1`, `-WhatIf` supported) — the missing reverse of the `irm | iex` installer. Removes `~/.ai-platform`, `~/.airlock-src`, the `$PROFILE` hook, and this platform's firewall rules; leaves Ollama and every pulled model alone.
- **`ai-doctor` now catches a stale local install.** Re-running `install.ps1`/`setup.ps1` always overwrote `~/.ai-platform`'s scripts from source — verified directly: 14 files differing before one resync run, 0 after — but nothing told you a resync was needed. `ai-doctor` now content-hashes `~/.airlock-src` against `~/.ai-platform` (normalized so a CRLF-vs-LF checkout artifact can't false-positive) and points at the fix. See [`ADR-011`](docs/adr/ADR-011-environment-sync-repo-to-installed.md).
- **Fixed while extending `ai-uninstall` to `~/.airlock-src`:** its leftover-redirect check ran *after* the deletion steps, meaning it could try to dot-source a file from a directory the script had just removed. Reordered to check first.
- **Memory service's retrieval-governance work (`ADR-007`) is now marked accepted.** It shipped in `0.3.0`/`0.4.0` below and was already described as done in that entry — the ADR's own Status line just never got flipped from "Proposed." Re-verified this pass: `pytest memory-service/tests/ -v`, 11/11 passing.

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
