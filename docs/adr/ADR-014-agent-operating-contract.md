# ADR-014: Agent operating contract — the repo tells the truth about local agentic coding

## Status
Accepted for implementation on `feature/adr-014-agent-operating-contract`.
Implements the AIR-014 slice of the 2026-09-04 program (014 operating contract → 015 Pi/Unsloth path → 016 coding-ready entry points → 017 harness debt). This ADR does not implement 015–017.

## Context

Two independent readers of this repository will currently get two different products:

1. **An agent that reads `CLAUDE.md` / `AGENTS.md`** is instructed to run `npm run build && npm test` (neither script exists; `package.json` only has `compile`/`watch` for a VS Code extension), to coordinate via Ruflo/`SendMessage`/hierarchical-mesh swarm, and to treat Darwin/Flywheel/MetaHarness as in-tree systems. `CLAUDE.md` on `main` mentions Airlock **zero** times, Ollama **zero** times, PowerShell **zero** times. Origin: `67c329d` ("chore: add ruflo agent/skill/command library and project CLAUDE.md").
2. **A human that reads `README.md` § tool-calling** is told the 2026-08-20 correction is current: pick a Tools-badged Ollama model, `qwen3-coder:30b` passed 3/3, point opencode at Ollama not the proxy, default `ollama/devstral-small-2:24b`. That 3/3 was a **single-call** probe. Live ADR-012 evidence on the same commit (`docs/adr/evidence/AGENT-005-repair-loop-live-evidence.md`) is 0/6 structured tool events on the repair-loop contract; `config/models.json` already records `qwen3-coder:30b` as "inconsistent for agentic coding sessions, not solved." `devstral-small-2:24b` later failed to emit structured `tool_calls` at the wire on Ollama.

The user-facing failure this session started from — "CLAUDE.md is not an accurate depiction; I am still fighting tool calling, reasoning, agentic AI coding" — is this split. Every new coding-agent session restarts the loop from the stale file, re-proposes live-failed models, and treats a static `supportsFunctionCalling: true` as a verdict.

This is the same shape ADR-012 named for runtime state ("five independently-green components can disagree"). Here the disagreement is in **the files an agent reads first**.

Related, not this ADR:

- ADR-012 / AGENT-001: `ai-start` still selects by VRAM/install, not agent eligibility.
- ADR-012 / AGENT-002: `ai-agent-start` / `ai-opencode` do not exist as profile functions.
- ADR-013 (unmerged, `feature/adr-013-pi-harness-verification`): the only passing agentic verdict is Unsloth Qwen3.8-27B via `llama-server` + Pi, 3/3. Not on `main`. Landing that path is AIR-015.
- spec-kit constitution v1.1.0 (`feature/spec-kit-adoption`) already treats `CLAUDE.md` as source of truth and has drifted from it. Out of scope here.

## Decision

**D1. `AGENTS.md` is the portable Airlock agent operating contract.** One file, every coding agent. It is not Claude-specific and not a Ruflo overlay. A first-time agent (Grok, Copilot, Gemini, Antigravity, Cursor, Claude Code, Codex, OpenCode) that reads `AGENTS.md` knows: this is a Windows PowerShell local-AI platform; how to run tests; which local models/runtimes are live-failed for agentic tool use and must not be retried; that Ollama/vLLM have no passing agentic verdict on the hardware this evidence was gathered on; that the one passing path lives on another branch and is not enabled here; that Ruflo/claude-flow is an optional MCP (`autoStart: false`), not the default orchestration.

**D2. Tool-specific filenames are thin adapters, not a second contract.** `CLAUDE.md` imports `AGENTS.md` with Claude Code's `@AGENTS.md` (Claude Code does not read `AGENTS.md` natively; a Windows symlink needs admin). `GEMINI.md` exists because Gemini CLI defaults to that name. `.github/copilot-instructions.md` exists for Copilot surfaces that only load that path. Cursor, Grok, Codex, and Copilot's AGENTS.md reader use the root file directly. Adapters must point at `AGENTS.md` and must not duplicate the known-failed ledger. No `.cursorrules` (legacy). Headroom RTK may remain as an optional appendix in `AGENTS.md` (the VS Code extension depends on `headroom-ai` markers); it is not required.

**D3. User-facing docs and the opencode template must not advertise a solved agentic path.** Specifically:

- `README.md` tool-calling section must stop presenting `qwen3-coder:30b` 3/3 single-call as "the bigger fix" without the 0/6 agentic result on the same page, in the same section.
- `config/opencode.json.template` must not default `model` to `ollama/devstral-small-2:24b` or `ollama/qwen2.5-coder:7b`. Default becomes `ollama/qwen3-coder:30b` **as a connection/chat default only**, matching the model that at least passed isolated single-call; the README and `AGENTS.md` must say this is not an agentic-ready default.
- `docs/08-Agent-CLI-Setup-Guide.md` must not claim `supportsFunctionCalling` "tells you upfront which models can reliably drive tool calls." That boolean is a seed (ADR-012).
- `docs/05-Provider-Fallback-Matrix.md` gets a short agentic-mode note: Ollama/vLLM are fine for chat/completion; they are not a verified agentic runtime on this evidence. No vLLM `local-limited` code marking here (AIR-017 / T087).

**D4. Honesty is machine-checked.** `scripts/Test-AgentOperatingContract.ps1` greps/JSON-reads the invariants in D1–D3. CI already runs every `scripts/Test-*.ps1`. A future edit that puts `npm run build && npm test` back in `AGENTS.md`, defaults opencode to devstral, or grows a second known-failed ledger inside `CLAUDE.md` / `GEMINI.md` / `copilot-instructions.md`, fails CI. Absence of a negative signal is not a pass — each invariant is a positive substring or a parsed JSON field (AGENT-004 discipline applied to docs).

**D5. Evidence wins over README.** `AGENTS.md` states: if README/CHANGELOG disagree with `docs/adr/evidence/` or `models.json` `agenticReliabilityNote`, evidence wins. Do not "correct" evidence to match marketing copy.

## What this explicitly does not change

- No merge of `feature/adr-013-pi-harness-verification` (AIR-015).
- No `ai-agent-start` / `ai-opencode` wrappers (AIR-016 / AGENT-002).
- No change to `Select-BestCuratedModel` / `ai-start` ranking (AIR-016 / AGENT-001).
- No flip of `candidateOnly` on `llamacpp-qwen38-ud-q3-k-xl` (AIR-015).
- No filing of the opencode 282K-skill issue (AIR-017).
- No deletion of stale remote branches (AIR-017).
- No Ruflo/MCP uninstall. `.mcp.json` stays; it just stops being the default story in `AGENTS.md`.
- `tool-proxy/` stays opt-in. This ADR does not revive "the proxy is the fix."
- `supportsFunctionCalling` keys stay in `models.json` as seeds. Wording around them changes; the schema does not (schema change is AIR-016 / T030).

## Consequences

**Positive**

- The next agent session cannot honestly re-propose qwen2.5-coder:7b, devstral, or xLAM as an agentic fix without ignoring a file it is required to read.
- CI fails closed if the operating contract is silently reverted to Ruflo-theater or a known-failed default model.
- Humans reading README see the same agentic status `models.json` already records.

**Negative**

- `AGENTS.md` will no longer load a ruflo-swarm playbook by default. Users who want that orchestration opt in via `.mcp.json`. That is the point.
- opencode's template default model change does not make opencode agentically reliable. It only stops pointing at a model that never emitted structured calls. Single-call ≠ agentic loop. Disclosed in README, not papered over.
- Docs will say "there is no passing agentic path on this branch." That is colder copy. It is also true.

## Evidence this ADR binds to (not re-derived here)

- `docs/adr/ADR-012-validated-local-agent-bootstrap.md` — primary acceptance FAIL; AGENT-001/002/005/006 open.
- `docs/adr/evidence/AGENT-005-repair-loop-live-evidence.md` — qwen3-coder:30b 0/6, webfetch hallucination.
- `config/models.json` `agenticReliabilityNote` on `qwen3-coder:30b` and `qwen2.5-coder:7b`.
- `feature/adr-013-pi-harness-verification` CLAUDE.md §2 and `docs/adr/evidence/ADR-013-unsloth-pi-live-verification.md` — known-failed ledger and the one 3/3 pass (Unsloth + llama-server + Pi). Cited, not merged.

## Next

AIR-015 lands the passing Pi/Unsloth path and then updates this contract from "not on this branch" to "this is the agentic profile." AIR-016 makes `ai-agent-start` the only coding door so the contract is enforced at the CLI, not just in markdown.
