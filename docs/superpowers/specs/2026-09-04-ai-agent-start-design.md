# AIR-016 — `ai-agent-start` design

Date: 2026-09-04
Status: Ready for implementation on `feature/adr-016-ai-agent-start`
ADR: `docs/adr/ADR-016-ai-agent-start.md`
Depends on: AIR-015 (`feature/adr-015-pi-unsloth-agentic-path` / #41) already merged or used as this branch's base.

Program: AIR-014 contract → AIR-015 Pi/Unsloth path → **AIR-016 (this spec)** → AIR-017 harness debt

## 1. Problem

The only live 3/3 agentic path (Unsloth Qwen3.8-27B UD-Q3_K_XL + llama-server + Pi) is catalogued and proven, but:

- no `ai-agent-start` command exists (AGENT-002)
- `huggingface-gguf` acquisition is unimplemented (AGENT-006)
- `Start-LlamaCppRuntime` is never called from a user path; default health timeout 30s cannot load 13 GB
- `ai-start` still hands users Ollama-by-VRAM
- Pi's `models.json` does not list the Unsloth id

## 2. Goal

After this branch merges, a user on Windows with the GGUF (or a confirmed download) can run:

```powershell
ai-agent-start            # default profile: llamacpp-qwen38-ud-q3-k-xl
ai-agent-start -WhatIf    # no process, no download, no config write
```

and either get a published `~/.ai-platform/state/active-agent.json` after a real Pi contract pass, or a fail-closed reason (VRAM, download declined, health timeout, template_unverified, contract fail).

`ai-code`, `ai-hermes-start`, and `Start-AgentSession -Harness pi-worker` refuse without that certificate.

## 3. Non-goals

- Changing `ai-start` / `Select-BestCuratedModel` chat ranking
- Re-running GPU 3/3 in CI
- opencode as a gate; xLAM; vLLM `local-limited`; vision/MTP; Unsloth's newer sampling kwargs
- Rewriting AIR-014 `AGENTS.md` except the one sentence that currently says the passing path is on another branch (do that only if #40 and #41 are already on the base)

## 4. Design

### 4.1 Command

Add `function global:ai-agent-start` in `scripts/profile-helpers.ps1` that invokes `scripts/Start-AgentSession.ps1` with defaults `-Profile llamacpp-qwen38-ud-q3-k-xl -Harness pi-worker`. Forward `-WhatIf`, `-ForceVerify`, `-NoCache`, `-Profile`.

`Start-AgentSession.ps1` `llama-server` branch today only adopts a snapshot. Change it to:

1. Resolve profile (schema already allows `candidateOnly` false; still require explicit `-Profile` — the wrapper supplies the default).
2. VRAM gate: `Get-AirlockFreeVramGiB` vs `minimumFreeVramGiB`; fail if below or nvidia-smi missing when the profile requires GPU layers `all`.
3. Acquire GGUF (4.2).
4. If no healthy snapshot for this `modelPath`, call `Start-LlamaCppRuntime` with profile `runtimeArgs`, `initialContext`, `HealthTimeoutSec=300`.
5. `/props` inspect; fail on `template_unverified`.
6. Run Pi contract unless a fresh capability-registry hit and `-ForceVerify` is off.
7. Publish certificate only on pass.

### 4.2 `huggingface-gguf` for llama-server

New helper (keep `Get-ModelAcquisition.ps1`'s Ollama `ollama create` path untouched):

- Parse `modelRef` `org/repo:QUANT` → HF repo `org/repo`, filename `{model}-UD-Q3_K_XL.gguf` for this profile (table-driven; first row is Unsloth Qwen3.8).
- Dest: `~/.ai-platform/models/Qwen3.8-27B-UD-Q3_K_XL.gguf`
- If dest exists and length is `13146393504`, skip download; record `matchedEvidenceBytes=true`.
- If dest exists and length differs: `matchedEvidenceBytes=false`; do not skip contract.
- If dest missing: require confirmation, then `hf download unsloth/Qwen3.8-27B-GGUF --include "*UD-Q3_K_XL*" --local-dir ...` (or equivalent Invoke-WebRequest of the resolved blob). No `ollama create`.

Unit-test the mapper and the skip/size-mismatch branches without network.

### 4.3 Health timeout

Change `Start-LlamaCppRuntime` default `$HealthTimeoutSec` from 30 to 300. 30s is why a naïve adapter call would kill the 13 GB load. Keep the parameter override.

### 4.4 Pi catalogue

Add to `hermes-container/config/models.json` `providers.ollama-local.models`:

```json
{ "id": "unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL", "name": "Unsloth Qwen3.8 27B UD-Q3_K_XL", "reasoning": true, "input": ["text"], "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }, "contextWindow": 8192, "maxTokens": 8192 }
```

Do not remove existing Ollama ids.

### 4.5 Ollama coding refuse

If `-Profile` resolves to `runtime: ollama`, `Start-AgentSession` prints the 0/6 / raw-JSON ledger and exits 1 unless a live contract in *this* run passes (it will not, on current evidence). No certificate. `ai-start` is the chat path.

### 4.6 Tests (TDD, no GPU)

`scripts/Test-AgentStart.ps1` (CI picks up `Test-*.ps1`):

| ID | Assert |
|----|--------|
| T1 | `profile-helpers.ps1` defines `ai-agent-start` |
| T2 | mapper: `unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL` → `Qwen3.8-27B-UD-Q3_K_XL.gguf` |
| T3 | existing file with size 13146393504 → skip download |
| T4 | existing file with other size → do not skip contract |
| T5 | `Start-LlamaCppRuntime` default HealthTimeoutSec is 300 (inspect via `Get-Command` / parse, or a small exported constant) |
| T6 | hermes `models.json` lists the Unsloth id |
| T7 | `Start-AgentSession -WhatIf -Profile llamacpp-qwen38-ud-q3-k-xl -Harness pi-worker` still exits 0 and prints openai-direct (existing test) |
| T8 | Ollama profile path does not publish a fixture certificate in the unit suite |

Do not add a Python test runner. If `pwsh` is absent in the implementer sandbox, run the Python mirror of T1–T6 and record the pwsh gap.

## 5. Fail-closed

- Confirmation declined → no download, no start, no certificate.
- VRAM below 14 GiB → no start.
- Health timeout → stop the process, no certificate.
- Template unverified → no certificate.
- Contract fail → no certificate, keep the JSONL audit.
- GGUF size ≠ evidence bytes → must run live contract; `-WhatIf` must say so.

## 6. Out of scope reminders

Do not "helpfully" point `ai-start` at llama-server. Do not enable MTP/vision. Do not change verified `runtimeArgs`. Do not merge xLAM.
