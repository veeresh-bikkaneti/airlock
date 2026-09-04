# Airlock — Agent Operating Contract

This file is the **portable operating contract** for every coding agent in this repo: Grok, GitHub Copilot, Google Gemini, Google Antigravity, Cursor, Claude Code, Codex, OpenCode, and anything else that reads `AGENTS.md`.

It is not a swarm playbook. It is not Claude-specific. Read it before looping on tools, models, or npm scripts.

Tool-specific filenames (`CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`) are **thin adapters**. They must point here. Do not grow a second copy of this contract in those files.

## What this repo is

Airlock is a hardened **single-instance local AI platform for Windows**.

- PowerShell lives in `scripts/`. Config lives in `config/`. Python services live in `memory-service/` and `tool-proxy/`.
- One Ollama **or** vLLM backend on port **12345**.
- This is **not** a Node web app. This is **not** a Ruflo / claude-flow product.
- `package.json` is only the VS Code extension (`compile`, `watch`). There is no platform `build` or `test` npm script.

### Tests — use these, not npm

- PowerShell: `pwsh -File scripts/Test-<Name>.ps1` (CI runs every `scripts/Test-*.ps1`)
- Python: `pytest memory-service/tests -v` and `pytest tool-proxy/tests -v`
- VS Code extension only: `npm run compile`
- **NEVER** a combined npm build-and-test command — those scripts do not exist

## Branching

- Feature branches only. Never commit to `main`.
- One branch per task. Keep branches short-lived. Push after real work. Delete after merge.
- Surgical edits. No secrets in the tree.
- Do not add `Co-Authored-By` unless the tool's project settings explicitly enable commit attribution.

## Known-failed local tool-calling candidates

**Do not retry these without new hardware or an upstream fix.** Agents that ignore this ledger restart failed tool-calling loops.

### VRAM spillover (13GB+, RTX 5000 Ada 16GB)

- Qwen3.8-27B via Ollama
- `qwen3.6:27b`
- `qwen3.6:35b-a3b` (GGUF `rope.dimension_sections` is 3; llama.cpp wants 4)
- Muse Glimmer 30B

### Fits VRAM but failed structured tool_calls on real agentic loops (all via Ollama, wire-level)

- `ornith:9b`
- `devstral-small-2:24b` — known-failed (narrates tool intent as plain text)
- `qwen2.5-coder:7b` — known-failed (prints tool JSON as text; unreliable for agentic sessions)
- `qwen3-coder:30b` — passed 3/3 isolated single-call; failed 0/3 and 0/6 on real multi-turn / agentic / repair-loop. Hallucinated webfetch to `withastro/astro` instead of reading local `spec.md`.

### Dead ends

- `xLAM-7b-fc-r-gguf` / `xlam-proxy`: dead end. Ceiling is extraction, not shell/EOS. `candidateOnly` stays `true`.
- Ruled out on size: DeepSeek-V4-Flash, GLM-5.3-Flash uncensored, OrcaRouter (not a local model).

### Runtime verdicts

- **Ollama** has no passing agentic verdict on this hardware.
- **vLLM** has zero live agentic verdict and is not marked local-limited yet (T087).
- Do **not** default users who need bash/read/write loops to Ollama or vLLM.

## Passing path (on `main`)

`llamacpp-qwen38-ud-q3-k-xl` (Unsloth Qwen3.8-27B UD-Q3_K_XL) via llama-server + Pi harness: **3/3 real tool events** (ADR-013 / AIR-015). Profile is in `config/agent-profiles.json` with `candidateOnly: false`. That flag is **not** a certificate.

- `ai-start` still selects Ollama by VRAM. Chat, not coding.
- `ai-agent-start` is the coding door (ADR-016): default profile `llamacpp-qwen38-ud-q3-k-xl`, harness `pi-worker`. It starts llama-server, acquires the GGUF, runs the Pi contract, and publishes `active-agent.json` only on pass. `candidateOnly: false` is still **not** a certificate.
- Unsloth Dynamic 3.0 ladder (ADR-018): on this 16 GB Ada card, **UD-Q3_K_XL is the coding quant**. `UD-Q4_K_XL` (17.6 GB) spills. A smaller step-down (`UD-IQ3_XXS`, `UD-Q2_K_XL`) is candidate-only and does not inherit the 3/3.
- Do not re-verify this profile on Ollama.

## Model flags are not verdicts

- `supportsFunctionCalling` in `config/models.json` is a **seed**, not a verdict.
- Ollama's "Tools" badge is editorial.
- `ai-start` selects by VRAM / install, not agent eligibility (**AGENT-001** open).
- `ai-agent-start` exists (**AGENT-002** / ADR-016). `ai-opencode` is still not a verified gate (AIR-017).

## Orchestration

Default is a **single agent doing the work**.

- Ruflo / claude-flow MCP is optional (`autoStart: false` in `.mcp.json`).
- Do not swarm, `SendMessage`, or `npx @claude-flow` as the default.
- The user can opt in.
- Delegation to subagents is fine for parallel research; that is not a Ruflo swarm.

## Docs vs evidence

If README / CHANGELOG disagree with `docs/adr/`, `docs/adr/evidence/`, or `models.json` `agenticReliabilityNote`, **evidence wins**. Do not "correct" evidence to match README.

## File hygiene

- Prefer edit over create. No new docs unless asked.
- New files under 500 lines.
- Tests live in `scripts/Test-*.ps1`, not `/tests`.

## Optional: RTK token filter

The block below is a Headroom (`headroom-ai`) cheat-sheet. It is **not** the product and **not** required. If `rtk` is not on PATH, ignore it. If it is, you may prefix noisy commands to cut token use.

<!-- headroom:rtk-instructions -->
# RTK (Rust Token Killer) - Token-Optimized Commands

When `rtk` is on PATH, you may prefix shell commands with `rtk`. This reduces context
usage by 60-90% with zero behavior change. If rtk has no filter for a command,
it passes through unchanged — so it is safe to use. It is optional.

## Key Commands
```bash
# Git (59-80% savings)
rtk git status          rtk git diff            rtk git log

# Files & Search (60-75% savings)
rtk ls <path>           rtk read <file>         rtk grep <pattern>
rtk find <pattern>      rtk diff <file>

# Test (90-99% savings) — shows failures only
rtk pytest tests/       rtk cargo test          rtk test <cmd>

# Build & Lint (80-90% savings) — shows errors only
rtk tsc                 rtk lint                rtk cargo build
rtk prettier --check    rtk mypy                rtk ruff check

# Analysis (70-90% savings)
rtk err <cmd>           rtk log <file>          rtk json <file>
rtk summary <cmd>       rtk deps                rtk env

# GitHub (26-87% savings)
rtk gh pr view <n>      rtk gh run list         rtk gh issue list

# Infrastructure (85% savings)
rtk docker ps           rtk kubectl get         rtk docker logs <c>

# Package managers (70-90% savings)
rtk pip list            rtk pnpm install        rtk npm run <script>
```

## Rules
- In command chains, prefix each segment: `rtk git add . && rtk git commit -m "msg"`
- For debugging, use raw command without rtk prefix
- `rtk proxy <cmd>` runs command without filtering but tracks usage
<!-- /headroom:rtk-instructions -->
