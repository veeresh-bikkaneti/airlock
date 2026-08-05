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
2. **Hugging Face is discovery-only.** `Get-ModelDiscoverySources` queries HF's GGUF search API and logs what it finds, but nothing downloads from it yet — deliberately scoped down per backlog story 2b, rather than adding remote-download complexity before it's needed. Story 4b in the backlog tracks closing this gap.
3. **Sizing uses system RAM (FreeMemGB) as the ceiling, regardless of GPU presence.** GPU info is computed and logged as informational/speed context only. Rationale: Ollama automatically offloads model layers that don't fit in VRAM to CPU/RAM, so GPU only affects inference speed, not whether a model can run. Fixed via `Get-ModelSizingCeilingGB` (`scripts/Get-ModelAcquisition.ps1:88`); see backlog story 2's resolution.
4. **Background pull is session-scoped** (`Start-Job`, not a detached process) — closing the terminal kills an in-progress pull. Already marked in-code as a `ponytail:` comment with its upgrade path (`Start-Process`).

## Consequences

**Positive**
- Provider Router and cloud fallback logic are untouched — acquisition is purely additive ahead of it.
- Audit logging shape (`Write-AuditLog`) is shared across both concerns; no second logging convention was introduced.
- No new entrypoint: users still just run `ai-start`.

**Negative**
- `scripts/Start-AI.ps1` is 557 lines, already over this project's own 500-line-per-file rule (`CLAUDE.md`), and acquisition logic (~380 lines: discovery, sizing, selection, background pull) is most of that growth. Story 4b (HF download + `ollama create` import) will add more to the same file.
- **Action item:** before story 4b lands, split acquisition (`Get-ModelDiscoverySources`, `Test-ResourceAvailability`, the auto-select block, the background-pull block) out of `Start-AI.ps1` into its own module, e.g. `scripts/Get-ModelAcquisition.ps1`, dot-sourced by `Start-AI.ps1`. Not done as part of this ADR since it's a pure refactor with no behavior change — tracked here so it isn't lost.

**Neutral**
- This repo has no `src/<context>/domain/` structure (it's PowerShell scripts + docs, not a layered app), so there's no bounded-context mapping to maintain here beyond this ADR and the blueprint's architecture diagram.

## Alternatives considered
- **Separate acquisition script/service, invoked before `Start-AI.ps1`.** Rejected: adds a second command users would need to run or the platform would need to shell out to, for a step that only matters at startup.
- **Extend the Provider Router to reach cloud-hosted GGUF repos proactively.** Rejected: conflates "which provider answers this chat request" with "does a local model exist at all," and is explicitly out of scope per `06-Model-Acquisition-Backlog.md`'s "Out of scope" section (no cloud-hosted acquisition fallback).
