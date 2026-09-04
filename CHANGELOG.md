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
