# ADR-001: Model acquisition is a pre-flight step inside Start-AI.ps1, not a Provider Router stage

## Status
Accepted (documents shipped behavior — commits `9fdb64f`..`324bdb9`)

## Context
[`01-Local-AI-Platform-Blueprint.md`](../01-Local-AI-Platform-Blueprint.md) defines the platform as:

```text
User
  -> PowerShell 7 profile helpers
  -> Local orchestration scripts
  -> Provider router
      -> Local: Ollama / localhost only
      -> Cloud fallback: OpenRouter, OpenAI, Anthropic, Google, Azure OpenAI
  -> AI coding client (for example aider)
  -> Project repository with manual review gates
  -> Logs + audit records + secret vault
```

The Provider Router assumes a model is already pulled and running in Ollama. [`06-Model-Acquisition-Backlog.md`](../06-Model-Acquisition-Backlog.md) requires zero-touch setup: nothing to install, nothing to pull by name, nothing to guess about hardware fit. Something had to decide *where in this flow* discovery, hardware sizing, selection, and pulling happen.

## Decision
Model acquisition runs as a **synchronous pre-flight sequence inside `scripts/Start-AI.ps1`**, before the Provider Router's local/cloud routing logic executes:

```text
User
  -> PowerShell 7 profile helpers
  -> scripts/Start-AI.ps1
      -> Test-ResourceAvailability          (Start-AI.ps1:205)  hardware profile
      -> Get-ModelDiscoverySources          (Start-AI.ps1:151)  Ollama curated list + HF discovery
      -> auto-select candidate              (Start-AI.ps1:272)  largest model that fits, 20% headroom
      -> background pull + warm-start       (Start-AI.ps1:454)  Start-Job, non-blocking
  -> Provider router                                             <- unchanged
      -> Local: Ollama / localhost only
      -> Cloud fallback: ...
  -> AI coding client, repo, logs, vault                          <- unchanged
```

It is not a separate acquisition service, and it does not extend the Provider Router itself. The router still only decides *where a chat-completion request goes* (local vs. cloud); acquisition's job is to guarantee the local branch has something to route to before that decision is ever made.

Decisions folded into this placement, previously undocumented:

1. **Ollama's "registry" is `config/models.json`'s curated `fallbackOrder`, not a live API call.** Ollama has no public "list all pullable tags" endpoint, so the curated list is the source of truth. Documented in [`05-Provider-Fallback-Matrix.md`](../05-Provider-Fallback-Matrix.md#model-acquisition-fallback).
2. **Hugging Face acquisition is wired.** `Get-ModelDiscoverySources` queries HF's GGUF search API and logs what it finds. When no curated Ollama model fits available hardware, `Get-HuggingFaceGGUFCandidate` queries individual HF repos for GGUF file details and sizes (via `Content-Length` HEAD requests when needed), and `Start-HuggingFaceImport` downloads the best-fitting file and imports it into Ollama via `ollama create`. Falls back to smallest curated model if HF search/download/import fails at any point. Implemented per backlog story 4b.
3. **Sizing prioritizes GPU free VRAM over RAM whenever any GPU is present** (`Start-AI.ps1:266`). Accepted as a known simplification, not fixed here — see backlog story 2's flagged gap.
4. **Background pull is session-scoped** (`Start-Job`, not a detached process) — closing the terminal kills an in-progress pull. Already marked in-code as a `ponytail:` comment with its upgrade path (`Start-Process`).

## Consequences

**Positive**
- Provider Router and cloud fallback logic are untouched — acquisition is purely additive ahead of it.
- Audit logging shape (`Write-AuditLog`) is shared across both concerns; no second logging convention was introduced.
- No new entrypoint: users still just run `ai-start`.

**Negative**
- (Previously: `scripts/Start-AI.ps1` exceeded 500-line rule, with acquisition logic as most of the growth. **Action item resolved:** acquisition logic has been split into `scripts/Get-ModelAcquisition.ps1` (containing `Get-ModelDiscoverySources`, `Test-ResourceAvailability`, `Select-BestModel`, `Get-HuggingFaceGGUFCandidate`, `Start-HuggingFaceImport`, and `Start-ModelAcquisitionPull`), dot-sourced by `Start-AI.ps1`.)

**Neutral**
- This repo has no `src/<context>/domain/` structure (it's PowerShell scripts + docs, not a layered app), so there's no bounded-context mapping to maintain here beyond this ADR and the blueprint's architecture diagram.

## Alternatives considered
- **Separate acquisition script/service, invoked before `Start-AI.ps1`.** Rejected: adds a second command users would need to run or the platform would need to shell out to, for a step that only matters at startup.
- **Extend the Provider Router to reach cloud-hosted GGUF repos proactively.** Rejected: conflates "which provider answers this chat request" with "does a local model exist at all," and is explicitly out of scope per `06-Model-Acquisition-Backlog.md`'s "Out of scope" section (no cloud-hosted acquisition fallback).
