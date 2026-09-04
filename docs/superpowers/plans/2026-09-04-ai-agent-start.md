# AIR-016 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship `ai-agent-start` so the proven Unsloth + llama-server + Pi path is a real door, not a scratchpad ritual.

**Spec:** `docs/superpowers/specs/2026-09-04-ai-agent-start-design.md`
**ADR:** `docs/adr/ADR-016-ai-agent-start.md`

## Global constraints

- Branch: `feature/adr-016-ai-agent-start`, based on `feature/adr-015-pi-unsloth-agentic-path`.
- Do not change `ai-start` ranking, Unsloth `runtimeArgs`, or merge xLAM.
- Do not re-run GPU 3/3 in CI. Unit tests only.
- Write the test file first (TDD). Confirm red on current 015 tip, then implement until green.

---

### Task 1: Red tests

**Files:** Create `scripts/Test-AgentStart.ps1`

- [ ] Assert `ai-agent-start` is missing (red) / then present (green after Task 2)
- [ ] Mapper, skip-download size, hermes models.json Unsloth id, HealthTimeoutSec default 300 — as T1–T6 in the spec

---

### Task 2: `ai-agent-start` wrapper + session start

**Files:** `scripts/profile-helpers.ps1`, `scripts/Start-AgentSession.ps1`, `scripts/runtime-adapters/llamacpp.ps1`

- [ ] Alias defaults `-Profile llamacpp-qwen38-ud-q3-k-xl -Harness pi-worker`
- [ ] llama-server branch calls `Start-LlamaCppRuntime` when no healthy snapshot
- [ ] Default `HealthTimeoutSec` 300
- [ ] VRAM gate vs `minimumFreeVramGiB`

---

### Task 3: huggingface-gguf for llama-server

**Files:** new helper next to `Get-ModelAcquisition.ps1` (do not route through `ollama create`)

- [ ] modelRef mapper
- [ ] confirmation
- [ ] size 13146393504 skip vs mismatch → ForceVerify

---

### Task 4: Pi catalogue + Ollama refuse

**Files:** `hermes-container/config/models.json`, `Start-AgentSession.ps1`

- [ ] Add Unsloth id under `ollama-local.models`
- [ ] Ollama `-Profile` does not publish a certificate without a live pass

---

### Task 5: Gates + CHANGELOG

**Files:** `docs/adr/evidence/ADR-016-GATES.md`, `CHANGELOG.md`

- [ ] Fill G1–G5 from `docs/adr/evidence/ADR-016-GATES.md`
- [ ] CHANGELOG top entry: AIR-016 door, not a new 3/3 claim
