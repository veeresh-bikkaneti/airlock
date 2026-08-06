# ADR-003: Optional vLLM local backend via `preferredLocalProvider`

## Status
Accepted

## Context
The platform hardcodes Ollama as the only local inference backend (single-instance, single source of truth on port 12345 — see README "Before This Platform" table). Ollama is broadly compatible (CPU/GPU, any OS), but vLLM offers meaningfully higher throughput for concurrent-request/batch workloads on NVIDIA GPUs. vLLM has no native Windows support — the only viable path is the official `vllm/vllm-openai` Docker image, requiring Docker Desktop + NVIDIA Container Toolkit + WSL2. This repo already has prior art for a sandboxed container (`hermes-container/`).

`config/policies/provider-policy.json` already has a `preferredLocalProvider` field, currently always `"ollama"` and not wired to anything. Users with a capable NVIDIA GPU should be able to opt into vLLM without requiring it, and without regressing the platform's single-instance invariant.

## Decision
Wire up the existing `preferredLocalProvider` field to let users opt into vLLM as an alternative to Ollama:

1. **Exclusive choice, not additive.** Exactly one local backend is active at a time — `preferredLocalProvider` is `"ollama"` or `"vllm"`, never both. No dual-backend-running mode.
2. **Same endpoint contract.** Both backends expose an OpenAI-compatible API on `127.0.0.1:12345`, so every downstream consumer (`ai-code`, VS Code extension, opencode/aider configs) needs zero changes.
3. **Capability-gated, one-time prompt.** `Start-AI.ps1` detects vLLM viability (NVIDIA GPU via `nvidia-smi`, Docker Desktop running) via a new `Get-BackendCapability.ps1`. If viable and no choice has been persisted yet, it prompts once and writes the answer to `preferredLocalProvider`. If not viable, it silently defaults to Ollama — never offers a choice that would just fail.
4. **New `Start-VLLM.ps1`**, mirroring `Start-AI.ps1`'s shape (audit logging, firewall guard, health-check polling), runs `docker run vllm/vllm-openai` with one hardcoded default model, binds `127.0.0.1:12345` only.
5. **Automatic fallback to Ollama** if the vLLM health check fails within its timeout (e.g. GPU unavailable, image pull failure) — logged, never silent, never left hanging.
6. **`Stop-AI.ps1`** stops whichever backend is active, reading `active-provider.json`.

MVP ships purely additively: zero behavior change to the existing Ollama path when vLLM isn't chosen or isn't viable.

## Consequences

**Positive**
- Users with an NVIDIA GPU get a meaningfully faster local backend for concurrent/batch workloads, opt-in only.
- Zero changes required from any downstream consumer — both backends converge on the same `http://127.0.0.1:12345/v1` contract.
- Existing Ollama path is untouched below the new selection block; the capability gate means most users (no NVIDIA GPU, or no Docker) see no behavior change at all.

**Negative**
- New surface area: `Get-BackendCapability.ps1`, `Test-BackendCapability.ps1`, `Start-VLLM.ps1`, plus insertion points in `Start-AI.ps1`, `Stop-AI.ps1`, `profile-helpers.ps1` (the `ai-port` health check moves from Ollama's `/api/tags` to the OpenAI-compatible `/v1/models` so it works for both backends).
- Adds a Docker + NVIDIA Container Toolkit + WSL2 dependency chain for the vLLM path only — not required for the default Ollama path.
- vLLM's throughput advantage is concurrent multi-user batching; this platform is single-user, so the win is real but secondary — framed as "give users the option," not a universal upgrade.

**Out of scope this pass** (revisit if a concrete need shows up):
- vLLM model picker / registry parity with `config/models.json` — MVP hardcodes one default model.
- WSL2-subprocess-without-Docker mode.
- Running Ollama and vLLM concurrently.
- Non-NVIDIA GPU support (AMD/ROCm etc.).

## Alternatives considered
- **Add a new config field instead of reusing `preferredLocalProvider`.** Rejected: the field already exists in `provider-policy.json` for exactly this purpose and is currently dead weight — reusing it avoids a second, redundant source of truth.
- **Run Ollama and vLLM concurrently, let the user pick per-request.** Rejected: directly contradicts the platform's core single-instance, single-source-of-truth invariant (README "Before This Platform" table); also doubles the resource footprint on a single-user machine for no clear benefit.
- **Bundle a native Windows vLLM build.** Rejected: vLLM has no first-class Windows binary; the only viable path is the official Docker image, so a native build isn't currently an option.
- **Silently downgrade to Ollama with no fallback logging when vLLM fails.** Rejected: inconsistent with this repo's audit-logging convention (ADR-001, ADR-002) — every state transition, including fallbacks, goes through `Write-AuditLog` plus a plain-language console message.
