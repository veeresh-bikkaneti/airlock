# Agent operating contract — design

Date: 2026-09-04
Status: Ready for implementation on `feature/adr-014-agent-operating-contract`
ADR: `docs/adr/ADR-014-agent-operating-contract.md`
Program: AIR-014 (this spec) → AIR-015 Pi/Unsloth path → AIR-016 coding-ready entry points → AIR-017 harness debt

## 1. Problem

`CLAUDE.md` on `main` describes a Ruflo/claude-flow swarm product. This repository is Airlock, a Windows PowerShell local-AI platform. User-facing docs still sell a 2026-08-20 "pick a Tools-badged Ollama model" fix that later live evidence falsified for agentic loops. Coding agents read the wrong file first and restart a failed tool-calling fight.

## 2. Goal

After this branch merges, a coding agent that reads `CLAUDE.md` and `AGENTS.md`, and CI that runs `scripts/Test-*.ps1`, cannot:

- believe this repo is a Node app whose test command is `npm run build && npm test`
- treat Ruflo swarm / SendMessage / Agent Booster as the default way to work here
- default opencode to `devstral-small-2:24b` or `qwen2.5-coder:7b`
- read README as saying `qwen3-coder:30b` 3/3 single-call solved agentic tool-calling

They will instead know: what Airlock is, how to test, which local candidates are live-failed, that Ollama/vLLM are not a verified agentic runtime here, and that the one passing path is on another branch.

## 3. Non-goals

- Merging `feature/adr-013-pi-harness-verification` or flipping `candidateOnly` (AIR-015)
- Implementing `ai-agent-start` / `ai-opencode` or changing `Select-BestCuratedModel` (AIR-016)
- Filing the opencode 282K-skill issue, marking vLLM `local-limited` in code, deleting stale remotes (AIR-017)
- Uninstalling Ruflo MCP; rewriting `tool-proxy`; changing `models.json` schema
- Re-running live model trials

## 4. Design

### 4.1 Invariant test is the contract (TDD)

`scripts/Test-AgentOperatingContract.ps1` is the source of checkable truth. It only reads files in the checkout. No Ollama, no Docker, no network. Same Assert-True style as `scripts/Test-WorkspaceContract.ps1`. CI picks it up automatically (`.github/workflows/ci.yml` runs every `scripts/Test-*.ps1`).

Write the test first. Confirm it fails on current `main` contents. Then change the docs/config until it passes.

### 4.2 `AGENTS.md` is the contract; tool files are adapters

Replace the Ruflo `CLAUDE.md` overlay. Put the operating contract in `AGENTS.md` (portable; 30+ agents read it). Target ≤ 220 lines of contract prose, RTK appendix allowed after. Required sections: product, tests, branching, known-failed ledger, passing path on another branch, seed flags, single-agent orchestration, evidence wins.

Thin adapters only — no second ledger:

- `CLAUDE.md` — Claude Code `@AGENTS.md` import
- `GEMINI.md` — Gemini CLI default filename
- `.github/copilot-instructions.md` — Copilot surfaces that ignore root `AGENTS.md`

Cursor, Grok, Codex, Antigravity: root `AGENTS.md`. No `.cursorrules`.

Forbidden in `AGENTS.md` and adapters: `npm run build && npm test`, Agent Booster, Darwin, Flywheel, MetaHarness, Haiku/Sonnet/Opus routing table, required `npx @claude-flow` before every task.

### 4.4 README tool-calling section

Rewrite the three paragraphs at README ~113–129 (model choice, the "bigger fix", opencode default). Preserve: native `/api/chat` vs OpenAI-compat correction (that part is still true); proxy is opt-in; port 12345; auto-select ignores tool reliability (AGENT-001 still open). Change: 3/3 single-call must sit next to 0/6 agentic; do not call Tools-badged Ollama "the bigger fix"; opencode default line must match the new template model and must not call it agentic-ready.

### 4.5 `config/opencode.json.template`

Change `"model"` from `ollama/devstral-small-2:24b` to `ollama/qwen3-coder:30b`. Leave the models map intact (including devstral as an offered model — offering ≠ defaulting). JSON has no comments; honesty lives in README + CLAUDE.md.

### 4.6 `docs/08-Agent-CLI-Setup-Guide.md`

- Before-you-start bullet that says `supportsFunctionCalling` "tells you upfront which models can reliably drive tool calls": rewrite to "is a seed, not a live verdict; see `agenticReliabilityNote` and ADR-012/014."
- Tool-use verification examples that use `qwen2.5-coder:7b` as if it might work: keep the example (it is the live-reproduced failure) but label it as the known failure, not a setup check to keep retrying.

### 4.7 `docs/05-Provider-Fallback-Matrix.md`

Add a short "Agentic coding (tool loops)" note under Local Backend Selection: chat/completion may use Ollama or vLLM; agentic bash/read/write loops have no passing Ollama or vLLM verdict on the evidence bound by ADR-014; do not treat a Tools badge as that verdict. Do not add a `local-limited` flag in scripts (AIR-017).

### 4.8 CHANGELOG

One new top entry: AIR-014 / ADR-014 — operating contract. Point at the README rewrite and the invariant test. Do not rewrite the 2026-08-20 entry (historical). The new entry must say the 2026-08-20 "bigger fix" was later falsified for agentic loops.

## 5. Invariants (testable)

See `scripts/Test-AgentOperatingContract.ps1` (written in the plan, implemented first). Summary:

| ID | File | Must |
|----|------|------|
| I1 | AGENTS.md | contains Airlock, Ollama, pwsh/PowerShell |
| I2 | AGENTS.md | does not contain `npm run build && npm test` |
| I3 | AGENTS.md | names qwen2.5-coder:7b, qwen3-coder:30b, devstral-small-2:24b as failed/do-not-retry |
| I4 | AGENTS.md | no Agent Booster, Darwin, Flywheel, MetaHarness |
| I5 | CLAUDE.md, GEMINI.md, .github/copilot-instructions.md | each points at AGENTS.md; none duplicate qwen2.5-coder:7b |
| I6 | opencode.json.template | parsed `model` is not `ollama/devstral-small-2:24b` and not `ollama/qwen2.5-coder:7b` |
| I7 | README.md | contains qwen3-coder:30b and 0/6 (or "inconsistent for agentic" / "not solved") |
| I8 | 08-Agent-CLI-Setup-Guide.md | does not contain the exact phrase "tells you upfront which models can reliably drive tool calls" |

## 6. Error handling / fail-closed

If the test cannot read a required file, that is a failure, not a skip. Partial matches that keep the old lie (e.g. README still saying "the bigger fix" while also appending 0/6 in a footnote) are resolved by rewriting the section, not by grepping a token into the footer. The plan's README task replaces the section; the test only checks the tokens the rewrite must leave behind.

## 7. Testing

- Red: run `pwsh -File scripts/Test-AgentOperatingContract.ps1` against current files; expect non-zero and FAIL lines for I1–I8.
- Green: after each file rewrite, re-run; last task requires a full pass.
- Regression: existing `scripts/Test-*.ps1` still run in CI; this task must not break their discovery (filename matches `Test-*.ps1`).

## 8. Out of scope reminders for implementers

Do not "helpfully" merge pi-harness files, add `ai-agent-start`, or download models. If CLAUDE.md needs to mention the passing Unsloth profile, name the other branch. Do not set `candidateOnly: false`.
