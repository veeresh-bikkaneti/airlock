# ADR-009: Multi-provider Claude Code profiles — subscription, OpenRouter, and local as one switch

## Status
Proposed. Extends `ai-claude-on` (see ADR-008). Depends on ADR-008 D2 (provenance).

## Context

`ai-claude-on` today has exactly one destination: the local Ollama backend, and it refuses when the active backend is vLLM. Meanwhile `config/policies/provider-policy.json` already carries a `cloudProviderPriority` of `["openrouter", "openai", "anthropic"]` with per-provider default models — but that path is the platform's *own* cloud fallback (used by aider and the memory service), not something Claude Code can reach. The result is that Claude Code is either local or nothing, while the policy file implies three cloud options exist.

Three things changed upstream that make a single switch feasible without any proxy:

1. **Ollama speaks the Anthropic Messages API natively** since v0.14.0 (announced 2026-01-16), at `/v1/messages`. <cite index="27-1">Ollama listens on its usual port, accepts requests in Anthropic's exact Messages format, translates internally, and returns Anthropic-format responses — no LiteLLM proxy, no translation layer.</cite> The same surface serves Ollama's cloud models via ollama.com, so local and subscription are one profile shape, not two. This is already the route `ai-claude-on` uses; what's new is that it also covers the cloud tier.
2. **OpenRouter exposes an Anthropic-compatible endpoint.** <cite index="14-1">Setting `ANTHROPIC_BASE_URL` to `https://openrouter.ai/api` lets Claude Code speak its native protocol directly to OpenRouter's "Anthropic Skin", which handles model mapping and passes through features like thinking blocks and native tool use. No local proxy is required.</cite>
3. **Anthropic's auth precedence makes profile switching clean, and is more precise than first stated here.** Per Anthropic's current authentication docs (code.claude.com/docs/en/authentication, "Authentication precedence"), `ANTHROPIC_AUTH_TOKEN` outranks `ANTHROPIC_API_KEY` outright — the docs say to use `AUTH_TOKEN` specifically "when routing through an LLM gateway or proxy that authenticates with bearer tokens," which is exactly airlock's shape (Ollama, OpenRouter). `ANTHROPIC_API_KEY` is documented for "direct Anthropic API access" and carries an approve/decline step: **in interactive mode**, the user is prompted once and the choice is remembered via a toggle in `/config`; **in non-interactive mode (`-p`), the key is always used when present** — the approval step doesn't apply there at all. That non-interactive carve-out matters for how this gets tested: a verification pass built around `claude -p` cannot exercise the decline path, because `-p` bypasses it by design. The risk is real for `ai-claude-on`'s actual use case (an interactive `claude` session), not for a `-p` smoke test of it — the two need to be verified separately, and only the interactive one confirms the original concern.

That last point is also a live bug, specifically in interactive use: `ai-claude-on` currently sets `ANTHROPIC_API_KEY = "ollama"`. Ollama ignores the key value, so this works — until a user has previously declined a custom API key in an *interactive* Claude Code session, at which point `ai-claude-on`'s injected key is silently skipped with no new prompt (the decline is remembered as a toggle in `/config`, not tied to that specific key value). `ANTHROPIC_AUTH_TOKEN` carries no such approval step and additionally outranks `ANTHROPIC_API_KEY` in precedence, so it can't be shadowed by a leftover API key some other tool set.

The subscription profile needs no variables at all — it is the absence of them. That falls straight out of the precedence rule above and is why this whole feature is a switch rather than a gateway.

## Decision

`ai-claude-on` takes a `-Profile` parameter with four values. Each profile is a named environment overlay plus a liveness target; the injection mechanism, stash/restore, and provenance from ADR-008 are unchanged.

| Profile | `ANTHROPIC_BASE_URL` | Credential | Liveness target |
|---|---|---|---|
| `anthropic` (default off-state) | *unset* | saved claude.ai login | `api.anthropic.com:443` |
| `local` (current behaviour, remains the default for `-Profile` omitted) | `http://127.0.0.1:<active port>` | `ANTHROPIC_AUTH_TOKEN=ollama` | active port |
| `ollama-cloud` | ollama.com endpoint | `ANTHROPIC_AUTH_TOKEN=<ai-auth-set ollama>` | endpoint host:443 |
| `openrouter` | `https://openrouter.ai/api` | `ANTHROPIC_AUTH_TOKEN=<ai-auth-set openrouter>` | `openrouter.ai:443` |

Supporting decisions:

- **`ANTHROPIC_AUTH_TOKEN` replaces `ANTHROPIC_API_KEY`** in all profiles, for the approval-prompt reason above. `ai-claude-off` clears both, since existing shells may hold the old variable.
- **`ai-claude-on anthropic` is a real profile, not a no-op.** It clears any redirect in the current shell and reports which credential source Claude Code will now use. This gives users a positive "put me back on my subscription" action instead of relying on them remembering `ai-claude-off`.
- **Credentials come from the existing `ai-auth-set` vault** (`~/.ai-platform/config/auth.json`, gitignored). No new secret store, and cloud profiles fail closed with a pointer to `ai-auth-set` when the key is missing — consistent with the platform's existing fail-closed policy.
- **Profiles are session-scoped like everything else.** No profile is ever persisted to `settings.json`; a settings-file `env` block would override the shell export and defeat the switch.
- **`ai-provider` and `ai-health` report the active Claude Code profile**, sourced from the ADR-008 provenance variables, so "what is Claude Code actually talking to right now" is answerable without reading environment variables by hand.
- **Companion variables are set per profile, not globally.** For any non-Anthropic profile, set `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`; Anthropic's troubleshooting guidance names it as the fix for `400` errors on unrecognized fields when a gateway forwards to an upstream that rejects what Claude Code sends to Anthropic-format endpoints.
- **No profile routes through the memory service.** The RAG proxy does not implement `/v1/messages`; the existing `directEndpoint` preference in `ai-claude-on` already handles this and must be preserved for the `local` profile.

**Rejected: running a translation proxy** (LiteLLM, y-router, claude-code-provider-gateway). All three destinations speak Anthropic Messages natively, so a proxy would add a process to supervise, a port to own, and a new dangling-pointer surface — the exact failure class ADR-008 exists to prevent. Worth noting that y-router's default port is **8787**, the same port that caused the incident; whatever airlock binds must never be 8787.

**Rejected: a vLLM profile.** vLLM's OpenAI-compatible server has no Messages API support documented anywhere in this repo, and `ai-claude-on` already refuses non-Ollama backends for that reason. Recorded here so it isn't rediscovered; revisit if vLLM ships `/v1/messages`.

## Consequences

**Positive**
- One command covers subscription, hosted-marketplace, and local inference, which is the actual daily workflow: burn local tokens on the cheap loop, switch to the subscription for the hard step, switch to OpenRouter when the subscription hits a limit.
- Hitting a cloud usage limit stops being a session-ending event — the `ai-handoff` call already wired into `ai-claude-on` records the switch, so ADR-006 handoff continuity extends to provider switches for free.
- The `ANTHROPIC_API_KEY` → `ANTHROPIC_AUTH_TOKEN` change removes a silent-failure mode in interactive sessions (a declined key is skipped with no new prompt) and, independently, uses the variable Anthropic's docs name for gateway/proxy routing rather than direct API access — the stronger of the two justifications, since it holds regardless of any prior approval state. Note for verification: a `claude -p` smoke test cannot confirm this fix, since `-p` mode always uses `ANTHROPIC_API_KEY` when present and never exercises the approval path being fixed.
- `cloudProviderPriority` in the policy file stops being aspirational for Claude Code specifically.

**Negative**
- Cloud profiles send code to a third party. This must be gated by the existing `allowSensitiveDataToCloud` policy and audit-logged like any other cloud call — a local-first platform silently gaining an easy cloud switch would undercut its own premise.
- More liveness targets means more network calls in `ai-doctor` and `ai-health`; cloud targets need a shorter timeout and must not fail the whole health check when offline.
- Non-Anthropic models behind the Anthropic protocol degrade in known ways: <cite index="25-1">Ollama's compatibility layer has no prompt caching, so every request reprocesses the system prompt and conversation history from scratch, and it ignores `tool_choice`, which can make Claude Code pick the wrong tool and loop.</cite> OpenRouter's own guidance is that Claude Code is only guaranteed against Anthropic first-party models. These belong in the docs as expected behaviour, not as bugs to be filed later.
- Ollama context length becomes a real constraint: <cite index="23-1">Ollama's own guidance is to run a model with at least 32K context for Claude Code, and its cloud models always run at full context length.</cite> On a 16 GB GPU that competes directly with model size — the ADR-005 VRAM ceiling now has a second claimant.
