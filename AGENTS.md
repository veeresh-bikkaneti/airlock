# Airlock — Agent Operating Contract

This file is the **portable operating contract** for every coding agent in this repo: Grok, GitHub Copilot, Google Gemini, Google Antigravity, Cursor, Claude Code, Codex, OpenCode, and anything else that reads `AGENTS.md`.

It is not Claude-specific and it does not require a hierarchical swarm. Read it before looping on tools, models, or npm scripts.

Tool-specific filenames (`CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`) are **thin adapters**. They must point here. Do not grow a second copy of this contract in those files.

## What this repo is

Airlock is a hardened **single-instance local AI platform for Windows**. The job is **any PC**, not the author ThinkPad: inspect this machine, pull an open-weight model that actually fits it, and if the user wants coding, prove tool-calling **on this machine** before trusting it. The Unsloth + Pi 3/3 on the RTX 5000 Ada is evidence bound to one box. It is not a certificate for anyone else.

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
- `ai-agent-start` is the coding door (ADR-016), harness `pi-worker`. **No `-Profile`:** size the Unsloth Dynamic 3.0 ladder to *this* PC's free VRAM, then a live Pi 3/3. Explicit `-Profile` still means that catalogue entry (never pick installed-but-unrequested). It starts llama-server, acquires the GGUF, runs the Pi contract, and publishes `active-agent.json` only on pass. `candidateOnly: false` is still **not** a certificate.
- Unsloth Dynamic 3.0 ladder (ADR-018): **UD-Q3_K_XL is the 16 GB-class GPU coding quant**. Smaller GPUs step down (`UD-IQ3_XXS` / `UD-Q2_K_XL`). If VRAM is too small but **system RAM can hold the GGUF**, `ai-agent-start` mmap's it on CPU (`--n-gpu-layers 0`). That is the "run a heavy model on RAM" path: same llama-server + Pi door, often 1–5 tok/s, live contract required, never inherit a GPU 3/3. Tiny RAM (under ~10 GB free) still refuses. `UD-Q4_K_XL` is **not shipped**: no profile entry, no quant-strategy branch picks it. Estimated ~24 GB VRAM need, gated on a new 3/3 — ADR-018 follow-up (see Product-Vision.md roadmap).
- Do not re-verify this profile on Ollama.
- Real cross-session memory (PENDING.md item 9, closed): when `ai-memory-start` is running, `ai-agent-start` auto-starts a second small CPU-only llama-server (EmbeddingGemma-300M) for embeddings and routes through memory-service's `/coding/v1/chat/completions` (recall + auto-persist of user turns) + `/coding/v1/memory/remember` (explicit persist). Pi 3/3 contract prompts are not stored. No Ollama involved. Fully optional, degrades to passthrough if the embedding runtime isn't up.

## Model flags are not verdicts

- `supportsFunctionCalling` in `config/models.json` is a **seed**, not a verdict.
- Ollama's "Tools" badge is editorial.
- `ai-start` selects by VRAM / install, not agent eligibility (**AGENT-001** open).
- `ai-agent-start` exists (**AGENT-002** / ADR-016). `ai-opencode` is still not a verified gate (AIR-017).

## Pre-implementation discussion gate

Every task must be discussed in the available agent chat room before implementation or mutation. Read-only workspace discovery may happen first. This is a planning and review gate, not a requirement to use a hierarchical swarm.

1. **Framing:** the lead posts the objective, constraints, workspace facts, proposed scope, acceptance criteria, unknowns, and verification plan.
2. **Independent review:** each available specialist posts recommendations, risks, assumptions, affected areas, test ideas, and a proceed/block recommendation. Specialists must challenge the plan rather than merely agree.
3. **Challenge:** the lead resolves disagreements and asks about security, dependencies, rollback, scope creep, and test gaps.
4. **Decision:** the lead records the plan version, owners, read sets, write sets, dependencies, checks, rollback, objections, approvals, and unresolved risks.

No implementation, mutation, migration, deployment, publication, or external side effect may begin until the discussion is approved. If no specialist is available, the lead performs and records the independent-review and challenge passes itself. Any unresolved critical security, data-loss, authorization, or scope objection blocks implementation. New scope, changed assumptions, workspace drift, or failed verification requires a focused re-discussion.

The harness should reject mutating tool calls while the gate is not approved. The agent must report **BLOCKED** rather than bypassing the gate. The reusable contracts are [`docs/agent-prompts/production-cli-lead.xml`](docs/agent-prompts/production-cli-lead.xml) and [`docs/agent-prompts/claude-lead.xml`](docs/agent-prompts/claude-lead.xml).

## Capability-based request routing

The lead must route work by **capability, evidence, and task fit**, never by vendor name, model branding, popularity, or a tool's marketing label. Claude, Grok, Copilot, Gemini, Codex, OpenCode, local models, and future agents are interchangeable implementations of capability slots. The harness should expose an agent registry with each agent's available tools, context limit, write permissions, network permissions, supported modalities, reliability evidence, cost/latency class, and current health.

### Routing procedure

1. **Classify the request:** determine whether it is conversation, repository research, implementation, debugging, testing, documentation, security review, data work, infrastructure, UI, or an external side effect. A task may have multiple tracks.
2. **Extract requirements:** identify required capabilities, read/write scope, language/runtime, data sensitivity, network needs, verification level, deadline, and whether the work can be parallelized.
3. **Select by hard constraints first:** exclude agents that lack a required tool, modality, permission, workspace access, safety authorization, or verified runtime support. A `supportsFunctionCalling` flag or vendor label is not sufficient evidence.
4. **Rank eligible candidates:** prefer the agent with the strongest task-specific evidence, then workspace/tool compatibility, then reliability, then latency/cost. Record the reason and evidence for the selection.
5. **Assign bounded roles:** choose one lead for integration and one owner per write set. Assign specialists only for independent research, review, or disjoint edits.
6. **Run the discussion gate:** selected agents discuss the plan before mutation. Agents that cannot participate in the chat room are reviewers at most, not implementation leads, unless the lead records a no-specialist fallback.
7. **Execute with checkpoints:** require a small, observable first step. After each tool result, reevaluate health, evidence, scope, and whether the selected agent remains fit.

### Capability routing matrix

| Request characteristic | Required capability | Route rule |
|---|---|---|
| Read-only repository question | Workspace read/search and synthesis | Use the lowest-cost eligible reader; no implementation agent is needed. |
| Code change | Workspace read/write, language/runtime competence, tests | Select an implementation lead with verified access to the exact repository and test tools. |
| Build or test failure | Shell/process control, logs, debugger, runtime access | Select an agent that can reproduce the failure; do not assign a text-only agent to execute it. |
| Security-sensitive change | Threat modeling, secure coding, relevant scanner or review capability | Require an independent security review before approval and verification. |
| Large independent investigation | Search/research, structured extraction, or domain expertise | Parallelize read-only subtasks; centralize synthesis and never overlap write sets. |
| UI, image, audio, or other modality work | The required modality tool and artifact verification | Exclude text-only agents; verify the actual rendered or generated artifact. |
| External side effect | Authorized connector, exact permission, and approval | Route only to an agent with the specific connector and authorization; otherwise block. |
| High-risk or irreversible operation | Policy knowledge, authorization, rollback, and human approval | Never infer capability from model identity; require an explicit approval checkpoint. |

### Fallback and anti-struggle rules

- If a tool call fails, classify the failure as **capability**, **permission**, **environment**, **input**, **dependency**, or **transient** before retrying.
- Do not retry an agent or tool for a capability failure. Route to the next eligible candidate or change the plan.
- Do not retry a permission failure. Request the missing authorization or report **BLOCKED**.
- For environment or dependency failures, repair only when that repair is in scope; otherwise escalate to the lead.
- Allow at most one focused retry after a changed premise or corrected input. After two materially different failures on the same objective, pause implementation and reopen the discussion gate.
- Never let agents repeatedly narrate intended tool calls without producing tool calls, repeatedly call unavailable tools, or silently substitute a weaker capability.
- If no eligible agent exists, return a capability gap containing the missing capability, attempted routes, evidence, safe alternatives, and the exact condition needed to proceed.
- When an agent becomes unhealthy, times out, loses workspace access, exceeds context limits, or produces unverifiable results, checkpoint the work, preserve artifacts, and fail over to an eligible agent. Do not discard the decision record.

### Routing decision record

For every implementation task, record `task_id`, request classification, required capabilities, excluded candidates and reasons, selected lead, specialists, evidence used, permissions, read sets, write sets, fallback candidates, checkpoints, and the next routing condition. This record is part of the discussion approval and must be updated when the route changes.

## Orchestration

Default is a **single agent doing the implementation**, preceded by the discussion gate above.

- Ruflo / claude-flow MCP is optional (`autoStart: false` in `.mcp.json`).
- Do not require `npx @claude-flow`, hierarchical mesh, or a specific swarm product.
- Delegation to subagents is allowed for bounded, independent research or disjoint edits with explicit owners and write sets.
- The lead owns decomposition, permissions, integration, conflict resolution, final verification, and the user-facing response.

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
