# ADR-013: llama.cpp + Pi is the agentic path; Ollama is not a verified agentic runtime

## Status
Accepted. Landed on `main` via [#41](https://github.com/veeresh-bikkaneti/airlock/pull/41).
`ai-agent-start` is AIR-016 ([#43](https://github.com/veeresh-bikkaneti/airlock/pull/43)).
vLLM `local-limited` remains AIR-017 / T087.

## Context

ADR-012 built a capability contract so "local agent ready" means a real tool-call round trip, not a static boolean. On `main`, that contract is implemented and the primary acceptance goal is still **FAIL**: Ollama-served models that fit VRAM do not complete structured multi-turn tool loops.

Live evidence already in-tree:

- `qwen2.5-coder:7b` — raw JSON as chat text, even on native `/api/chat`.
- `qwen3-coder:30b` — 3/3 isolated single-call; **0/6** on the repair-loop contract (`docs/adr/evidence/AGENT-005-repair-loop-live-evidence.md`).
- `devstral-small-2:24b` — fits VRAM, never emits structured `tool_calls` at the wire.

A separate branch, `feature/adr-013-pi-harness-verification`, then proved one combination **3/3** with real `read`/`write` tool events: Unsloth Qwen3.8-27B UD-Q3_K_XL served by `llama-server`, driven by the Pi harness inside `hermes-container`. That proof required fixing real plumbing (AGENT-PI-01: PowerShell `Start-Process -ArgumentList` word-splitting a multi-word instruction; four earlier Pi wiring bugs in the Dockerfile/entrypoint/`--prompt` flag/out-of-workspace regex). The model was held constant; the first live run hung because of argv quoting, not because the model could not call tools.

xLAM-7b via a translation proxy (`feature/adr-013-xlam-proxy-plan`) is a documented dead end: toy single-call extraction can look green; the live multi-tool contract fails. Ceiling is extraction, not shell/EOS. Not merged here.

## Decision

**D1. The agentic runtime on this hardware is `llama-server` (llama.cpp), not Ollama and not vLLM.** Every Ollama-served candidate tried so far failed structured tool-calling at the wire. vLLM has no live agentic verdict. Chat/completion may still use Ollama or vLLM.

**D2. The first coding-ready profile is `llamacpp-qwen38-ud-q3-k-xl`.** `candidateOnly` becomes `false` because the ADR-012 Pi contract passed 3/3 with observed tool events, not because a human flipped a boolean. Runtime args stay exactly as verified: `--jinja`, `--flash-attn`, `on`, `--n-gpu-layers`, `all`, `--reasoning-effort`, `low`. Context 8192.

**D3. The proving harness for that profile is Pi inside `hermes-container`, not opencode.** opencode `--auto` on the author's machine built a ~282K-token skill dump (AIR-017 to file upstream). That is an environmental blocker, not a model failure. Do not re-run this candidate through opencode as a gate.

**D4. Land the verified code and evidence from `origin/feature/adr-013-pi-harness-verification` without its `CLAUDE.md` edits.** AIR-014 owns `CLAUDE.md`. The files this ADR owns:

- `config/agent-profiles.json`
- `hermes-container/Dockerfile`
- `hermes-container/entrypoint.sh`
- `scripts/Invoke-PiCapabilityContract.ps1`
- `scripts/Test-PiCapabilityContract.ps1`
- `docs/adr/evidence/ADR-013-unsloth-pi-live-verification.md`
- `docs/adr/evidence/ADR-013-unsloth-fallback-GATES.md`

**D5. Do not merge xLAM proxy code.** `candidateOnly` for any xLAM profile stays true if present; this branch does not add `xlam-proxy/`.

## What this explicitly does not change

- `CLAUDE.md`, `AGENTS.md`, `README.md`, `config/opencode.json.template` (AIR-014).
- `scripts/profile-helpers.ps1` — still no `ai-agent-start` (AIR-016 / AGENT-002).
- `Select-BestCuratedModel` ranking (AIR-016 / AGENT-001).
- vLLM launch flags / `local-limited` marking (AIR-017 / T087).
- Re-running the 3 live GPU trials in CI. Evidence is bound to the author's RTX 5000 Ada 16GB machine and the commit recorded in the evidence doc. CI runs the unit contract (`Test-PiCapabilityContract.ps1`), not the GPU loop.

## Consequences

**Positive**

- `main` (after merge) contains a profile that has actually earned `candidateOnly: false` for agentic use, plus the Pi wiring that made the proof possible.
- Future agents cannot treat "we have a passing local agentic path" as a rumor on an unmerged branch.

**Negative**

- The passing path still is not a one-command user door (`ai-agent-start` is AIR-016). A user who only runs `ai-start` still gets Ollama-by-VRAM.
- llama-server still has no VRAM/residency fit adapter (FIT-ADAPTERS-001). A false-pass on a machine that cannot hold 13GB is possible. Disclosed, not silent.
- Evidence is hardware-bound. A different GPU must re-run the contract; this merge does not generalize the 3/3.
- ADR-012's original schema rejected `candidateOnly: false`, which made this promoted profile unloadable (`Test-AirlockProfileSchema` + every `Start-AgentSession`). Schema now accepts both booleans: `true` = unproven, `false` = earned by a live contract. The flag is still not a certificate.

## Evidence this ADR binds to

- `docs/adr/evidence/ADR-013-unsloth-pi-live-verification.md` (3/3, raw tool events, AGENT-PI-01).
- `docs/adr/evidence/ADR-013-unsloth-fallback-GATES.md`.
- `docs/adr/evidence/AGENT-005-repair-loop-live-evidence.md` (Ollama + qwen3-coder:30b 0/6).
- `docs/adr/ADR-012-validated-local-agent-bootstrap.md`.

## Next

AIR-016 landed on `main` ([#43](https://github.com/veeresh-bikkaneti/airlock/pull/43)).
Remaining: live `ai-agent-start` on the ThinkPad, AGENT-001, AIR-017 / T087.
See [PENDING.md](PENDING.md). Quant ladder is [ADR-018](ADR-018-unsloth-quantization-strategy.md).
