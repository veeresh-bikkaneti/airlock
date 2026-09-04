# AIR-016 `ai-agent-start` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `ai-agent-start` so the proven Unsloth + llama-server + Pi path is a real coding door that publishes `active-agent.json` only after a live Pi pass, or fails closed.

**Architecture:** Keep `Start-AgentSession.ps1` as the only certificate publisher. Add a thin `ai-agent-start` wrapper that supplies the default Unsloth profile + `pi-worker`. Add a new llama-server-only GGUF helper (do not reuse `Start-HuggingFaceImport` / `ollama create`). Raise llama-server health timeout to 300s and call `Start-LlamaCppRuntime` when no healthy snapshot exists. Gate VRAM before start. Refuse Ollama coding certificates unless a live contract passes *this run*. Coding consumers (`ai-code`, Pi worker, `ai-hermes-start` via `run-hermes.ps1`) require an unexpired cert; `ai-switch` invalidates it.

**Tech Stack:** PowerShell 7+, existing `Test-*.ps1` Assert-True convention, llama-server, Pi hermes-container, no Pester, no GPU in CI.

**Spec:** `docs/superpowers/specs/2026-09-04-ai-agent-start-design.md`

**ADR:** `docs/adr/ADR-016-ai-agent-start.md`

## Global Constraints

- Branch: `feature/adr-016-ai-agent-start` off current `main` (AIR-014/015/016 spec already landed).
- Do not change `ai-start` / `Select-BestCuratedModel` ranking.
- Do not change Unsloth `runtimeArgs`.
- Do not merge xLAM. Do not re-run GPU 3/3 in CI.
- Do not route `huggingface-gguf` through `ollama create`.
- `Resolve-AirlockProfileSelection` must keep failing when `-Profile` is omitted (default lives only in `ai-agent-start`).
- Unit tests only. Evidence bytes constant is exactly `13146393504`.
- Default HealthTimeoutSec is `300`.
- Certificate is the verdict; `candidateOnly: false` is not a certificate.

## File map

| File | Responsibility |
|------|----------------|
| Create `scripts/Get-HuggingFaceGguf.ps1` | Pure mapper + skip/mismatch + I/O acquire for llama-server GGUF only |
| Create `scripts/Test-AgentStart.ps1` | T1–T8 plus D1/D7/D9 string/pure gates |
| Modify `scripts/runtime-adapters/llamacpp.ps1` | Default `$HealthTimeoutSec = 300` |
| Modify `scripts/agent-profile-helpers.ps1` | `Resolve-AirlockVramStartGate`, `Resolve-AirlockOllamaCodingCertificate` |
| Modify `scripts/agent-state-helpers.ps1` | `Clear-AirlockActiveAgentCertificate` |
| Modify `scripts/Start-AgentSession.ps1` | VRAM gate, GGUF acquire, auto-start llama-server, Ollama refuse, provenance |
| Modify `scripts/profile-helpers.ps1` | `ai-agent-start`; `ai-code` cert gate; `ai-switch` invalidates |
| Modify `scripts/Start-AgentWorkerJob.ps1` | Refuse without unexpired `pi-worker` cert |
| Modify `hermes-container/config/models.json` | Add Unsloth id under `ollama-local.models` |
| Modify `docs/adr/evidence/ADR-016-GATES.md`, `CHANGELOG.md`, `AGENTS.md`, ADR-016 status | Honest docs |

---

### Task 1: Red tests

**Files:**
- Create: `scripts/Test-AgentStart.ps1`

**Interfaces:**
- Consumes: nothing (asserts current tree is missing the door).
- Produces: failing T1–T8 that turn green in later tasks.

- [ ] **Step 1: Write the failing test** (see `scripts/Test-AgentStart.ps1` in this commit)
- [ ] **Step 2: Run test to verify it fails**

```bash
pwsh -File scripts/Test-AgentStart.ps1
```

Expected: FAIL on T1 (`ai-agent-start` missing), T2 (mapper missing), T5 (timeout still 30), T6 (Unsloth id missing).

- [ ] **Step 3: Commit the red test**

---

### Task 2: GGUF mapper + skip/mismatch (D3 pure)

**Files:**
- Create: `scripts/Get-HuggingFaceGguf.ps1`
- Test: `scripts/Test-AgentStart.ps1` T2–T4

**Interfaces:**
- Produces:
  - `ConvertTo-AirlockGgufFileName([string]$ModelRef) -> [string]`
  - `ConvertTo-AirlockHfRepo([string]$ModelRef) -> [string]`
  - `Get-AirlockGgufDestPath([string]$ModelRef, [string]$PlatformDir) -> [string]`
  - `Test-AirlockGgufEvidenceMatch([long]$ByteLength) -> [bool]`
  - `Resolve-AirlockGgufAcquisition([bool]$DestExists, [long]$DestLength, [bool]$UserConfirmed) -> { Action, MatchedEvidenceBytes, ForceVerify, Reason }`
    - Actions: `SkipDownload` \| `UseExistingMismatch` \| `RequireConfirmation` \| `Download`
  - Evidence constant: `13146393504`
  - `Get-AirlockHuggingFaceGguf` I/O: never calls `ollama create`

- [ ] Implement mapper + Resolve-AirlockGgufAcquisition
- [ ] Run `pwsh -File scripts/Test-AgentStart.ps1` — T2–T4 green; T1/T5/T6 still red
- [ ] Commit

---

### Task 3: Timeout 300 + Pi catalogue + VRAM/Ollama gates

**Files:**
- Modify: `scripts/runtime-adapters/llamacpp.ps1` (`HealthTimeoutSec` default 30 → 300)
- Modify: `hermes-container/config/models.json`
- Modify: `scripts/agent-profile-helpers.ps1`
- Modify: `scripts/agent-state-helpers.ps1`

**Interfaces:**
- `Start-LlamaCppRuntime -HealthTimeoutSec` default `300`
- `Resolve-AirlockVramStartGate(-FreeVramGiB, -MinimumFreeVramGiB, -RequiresGpuLayersAll) -> { Allowed, Reason }`
  - `$null` free VRAM + GPU-layers-all → refuse
  - free < minimum → refuse
- `Resolve-AirlockOllamaCodingCertificate(-LiveContractPassedThisRun) -> { Allow, Reason }`
  - Allow only when live pass this run is true
- `Clear-AirlockActiveAgentCertificate(-CertificatePath)` deletes the file if present
- models.json adds `{ "id": "unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL", "name": "Unsloth Qwen3.8 27B UD-Q3_K_XL", "reasoning": true, "input": ["text"], "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }, "contextWindow": 8192, "maxTokens": 8192 }`

- [ ] Implement
- [ ] T5/T6 green
- [ ] Commit

---

### Task 4: Session start + wrapper + coding-door gates

**Files:**
- Modify: `scripts/Start-AgentSession.ps1`
- Modify: `scripts/profile-helpers.ps1`
- Modify: `scripts/Start-AgentWorkerJob.ps1`

**Interfaces:**
- `ai-agent-start` defaults `-Profile llamacpp-qwen38-ud-q3-k-xl -Harness pi-worker`; forwards `-WhatIf`, `-ForceVerify`, `-NoCache`, `-Profile`, `-DownloadConfirmed`
- llama-server branch: VRAM gate → GGUF acquire → `Start-LlamaCppRuntime` if no healthy snapshot for this `modelPath` → `/props` Pass
- Ollama branch: `Resolve-AirlockOllamaCodingCertificate`; do not publish from cache
- `ai-code` / `Start-AgentWorkerJob` call `Resolve-AirlockCertificateValidity -CompatibleHarnesses @('pi-worker')`
- `ai-switch` calls `Clear-AirlockActiveAgentCertificate` on successful model switch

- [ ] Implement
- [ ] All Test-AgentStart checks green
- [ ] Existing `Test-StartAgentSession.ps1`, `Test-LlamaCppAdapter.ps1`, `Test-AgentProfileHelpers.ps1`, `Test-AgentStateHelpers.ps1`, `Test-StartAgentWorkerJob.ps1` still pass
- [ ] Commit

---

### Task 5: Docs + gates

**Files:** `docs/adr/evidence/ADR-016-GATES.md`, `CHANGELOG.md`, `AGENTS.md`, `docs/adr/ADR-016-ai-agent-start.md`

- [ ] Check G1–G5
- [ ] CHANGELOG: AIR-016 door, not a new 3/3 claim
- [ ] AGENTS.md: `ai-agent-start` is implemented; still not a GPU 3/3 in CI
- [ ] ADR-016 status → Implemented on this branch
- [ ] Commit
