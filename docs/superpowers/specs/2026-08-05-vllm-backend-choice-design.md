# vLLM as an optional local backend — design

Date: 2026-08-05
Status: Implemented — `Get-BackendCapability.ps1`, `Start-VLLM.ps1`, `Start-AI.ps1` backend-selection block, and `Stop-AI.ps1` vLLM-stop path all match this design.

## Problem

Platform currently hardcodes Ollama as the only local inference backend
(single-instance enforced on port 12345). Ollama is broadly compatible
(CPU/GPU, any OS) but vLLM offers meaningfully higher throughput for
concurrent-request / batch workloads on NVIDIA GPUs. Users with a capable
NVIDIA GPU should be able to opt into vLLM instead of Ollama, without
requiring it (vLLM has no native Windows support — GPU + Docker/WSL2 only).

## Constraints

- Platform is Windows-only, PowerShell-native (`Start-AI.ps1`,
  `Stop-AI.ps1`, `profile-helpers.ps1`).
- Core architectural invariant: **single-instance, single source of truth**
  for which model/port is active (README "Before This Platform" table).
  This must not regress — no dual-backend-running mode.
- vLLM has no first-class Windows binary. Only viable path is a container
  (official `vllm/vllm-openai` Docker image) requiring Docker Desktop +
  NVIDIA Container Toolkit + WSL2 backend. This repo already has prior art
  for a sandboxed container (`hermes-container/`).
- vLLM's throughput advantage is concurrent multi-user batching. This
  platform is single-user; the win is real but secondary to "give users
  the option," not a claimed universal upgrade.

## Decision

Reuse the existing `preferredLocalProvider` field in
`config/policies/provider-policy.json` (currently always `"ollama"`).
Allow value `"vllm"`. Exactly one backend is active at a time — this is
an *exclusive* choice, not an additive one. Both backends expose an
OpenAI-compatible API on `127.0.0.1:12345`, so every downstream consumer
(`ai-code`, VS Code extension, opencode/aider configs) needs zero changes.

## Components

- **`scripts/Get-BackendCapability.ps1`** (new). Detects whether vLLM is
  viable: NVIDIA GPU present (`nvidia-smi` exists and returns a device),
  Docker Desktop running, WSL2 backend enabled. Returns a bool.

- **`Start-AI.ps1`** (modified). On first run — i.e. no backend choice
  recorded yet in `provider-policy.json` — if `Get-BackendCapability`
  reports vLLM viable, prompt the user: "Ollama (works everywhere) or
  vLLM (NVIDIA GPU, faster for concurrent requests)?" Persist the answer
  to `preferredLocalProvider`. If vLLM isn't viable, skip the prompt
  entirely and default to Ollama silently — never offer an option that
  will just fail.

- **`scripts/Start-VLLM.ps1`** (new, mirrors `Start-AI.ps1`'s shape:
  audit logging, firewall guard, health-check polling). Runs
  `docker run vllm/vllm-openai` with one hardcoded default model (a
  coder model comparable in size/role to `qwen2.5-coder:7b`), binds
  `127.0.0.1:12345` only, reuses the existing firewall-guard pattern
  (rule naming generalized from `AI-Platform-Ollama-Block-$Port` to
  `AI-Platform-Backend-Block-$Port`), polls `/health` up to 20s like the
  Ollama path does today.

- **`Stop-AI.ps1`** (modified). When `preferredLocalProvider` is
  `"vllm"`, `docker stop`/`docker rm` the container instead of killing
  `ollama` processes.

- **`config/models.json`**: untouched this pass. MVP ships one hardcoded
  default vLLM model; no registry entry, no picker.

## Data flow

```
ai-start
  → read preferredLocalProvider from provider-policy.json
  → "ollama"  → existing Start-AI.ps1 flow, unchanged
  → "vllm"    → Start-VLLM.ps1:
                  check container not already running
                  docker run vllm/vllm-openai (default model)
                  poll http://127.0.0.1:12345/health
                  apply firewall guard
                  Write-AuditLog -Action VLLMStart -Result SUCCESS
  → both paths converge on the same endpoint contract:
    http://127.0.0.1:12345/v1  (OpenAI-compatible)
```

Every downstream tool talks to that one endpoint regardless of which
backend is behind it.

## Error handling

- Docker Desktop not running, or no NVIDIA GPU detected at prompt time →
  vLLM option is never offered; user isn't shown a choice that can't
  work.
- User previously chose vLLM but the GPU becomes unavailable (e.g.
  laptop undocked from eGPU) → `Start-VLLM.ps1` health check fails
  within the timeout → automatically fall back to starting Ollama
  instead, log `Result: FAILED` for the vLLM attempt plus the fallback,
  warn the user in the console. Never hang waiting on a dead container.
- Docker image pull failure (no network, first run) → same
  fallback-to-Ollama path, logged.

## Testing

- Automated smoke check: `Get-BackendCapability.ps1` returns the correct
  bool given mocked `nvidia-smi` / Docker-state inputs (ponytail rule:
  one runnable check per non-trivial branch/parser, not a full suite).
- Manual regression: `ai-start` on a non-NVIDIA machine → vLLM prompt
  never appears, Ollama starts exactly as it does today.
- Manual: `ai-start` on an NVIDIA + Docker Desktop machine → choose
  vLLM → confirm `/v1/chat/completions` responds and `ai-code` works
  with no changes on the client side.

## Explicitly out of scope (this pass)

- vLLM model picker / registry parity with `config/models.json`.
- WSL2-subprocess-without-Docker mode.
- Running Ollama and vLLM concurrently.
- Non-NVIDIA GPU support for vLLM (AMD/ROCm etc.) — revisit if/when vLLM's
  Windows/ROCm story matures.

Add any of the above when a concrete need for it shows up, not before.
