# ADR-013 Evidence: DeepSeek Harness (dsh) Feasibility Scoping

**Status:** Investigation only — no wiring performed. This is a scoping doc, not an implementation.
**Repo evaluated:** `deepseek-ai/deepseek-harness` (public, DeepSeek-official, ~209k stars, created 2026-08-13)
**Evaluated at:** 2026-09-02, HEAD tag `dsh-v0.1.2-alpha.5` (published same day)
**Method:** `gh api` reads of real file contents (docs, package manifests, source-map READMEs) and `gh api graphql` reads of the repo's GitHub Discussions. No file was fabricated or guessed; every claim below cites the artifact it came from.

## Recommendation

**Wait.** Do not adopt now, and do not adopt behind a pin for this deadline. Revisit only if the parallel Pi verification (`feature/adr-013-pi-harness-verification`) also dead-ends *and* dsh has shipped a non-prerelease tag.

dsh's architecture is genuinely more promising on paper than opencode's — it does not share opencode's failure mode — but the project is 3 weeks old, has shipped zero stable releases, and its two freshest community bug reports (both filed within the last 24–48 hours of this evaluation) land squarely in the two paths this team would have to exercise: third-party/gateway request-shape compatibility, and reasoning-heavy turns. Adopting it now would mean debugging DeepSeek's own harness bugs on a hard 2-month deadline, not verifying a model.

## Q1 — Local-model support: real, but not through the package named after DeepSeek

dsh ships two separate LLM adapter packages and they behave oppositely for local/self-hosted use:

- **`@deepseek-ai/dsh-llm-pi-ai`** (`packages/llm/llm-pi-ai`) is a genuine multi-provider adapter. Its `providers` dictionary supports **hand-declared routes** — a "custom provider" is configuration, not a code change: give it `api: openai-completions` (or `openai-responses`), a `baseURL`, and a `models` list, and it will talk to any OpenAI-compatible server, including a local `llama-server`/Ollama endpoint. Per `docs/user/guide/providers.md`, a `compat` block corrects for endpoints that don't fully match OpenAI's wire shape (`supportsDeveloperRole: false`, `maxTokensField: max_tokens`, `thinkingFormat`), which is exactly the kind of correction a self-hosted `llama-server` needs. No DeepSeek API key is required on this path.
  - Notably, `package.json` pins `"@earendil-works/pi-ai": "^0.84.2"` as a runtime dependency — this is **the same `@earendil-works` vendor namespace** as `@earendil-works/pi-coding-agent`, the Pi harness the `pi-verifier` sibling agent is live-verifying in parallel on this repo. dsh's local/self-hosted routing is not DeepSeek-bespoke; it's inherited from pi-ai's own provider abstraction. This is worth flagging back to whoever owns the Pi verification thread — the two evaluations share a dependency.
- **`@deepseek-ai/dsh-llm-deepseek`** (the DeepSeek-native adapter, used for the `deepseek-official` route) is a trap for local use: it unconditionally injects a diagnostic field, `dsh_plugin_packages`, into every request regardless of `baseURL` — confirmed as *intentional, documented* behavior (not a bug) in [Discussion #5293](https://github.com/deepseek-ai/deepseek-harness/discussions/5293), filed 2026-09-01. Any strict OpenAI-compatible validator that rejects unknown top-level fields (which a llama.cpp/Ollama-fronting gateway plausibly would) 400s on every request: `Unsupported request parameter(s): dsh_plugin_packages`. The maintainer-side reply confirms there is no baseURL-conditional exemption in source — only an opt-out flag the operator must proactively find and set.

**Conclusion:** local endpoints work, but only by deliberately using `llm-pi-ai`'s custom-provider path and never letting `llm-deepseek`'s default routing anywhere near a self-hosted server.

## Q2 — Tool-calling and agentic looping: real, comparable to opencode/Pi

`packages/core` (per its README) is "the product API spine": an append-only session log, system-prompt assembly, a **tool registry** (`ctx.tools`), an `Agent` handle (`ctx.agents`), and `agent-loop`, "the default agent driver: creates agents and runs the turn and step lifecycle." This is a real agentic loop, not a chat wrapper.

`docs/subsystems/tools.md` documents `ToolDefinition extends ToolSchema` — the registry's `schemas()` builds the model-facing array via an **explicit allowlist**, sending only `name`/`description`/JSON-Schema `parameters` to the model (execution internals like `execute`, timeouts, and presenters are explicitly barred from leaking into the request). This is the same shape as OpenAI's `tools` API that this repo's existing profiles already speak. The execution pipeline supports concurrency-safe parallel tool calls, per-tool cooperative timeouts, and cancellation via `AbortSignal` — production-grade, not a toy.

## Q3 — Reasoning/deep-thinking mode: explicit, first-class, settings-level

`llm-pi-ai`'s model config takes a `reasoningEfforts` map: each key is a selectable level (e.g. `off`, `high`), each value the exact wire spelling that endpoint expects (`max: ultra` renames a level for a gateway with its own vocabulary). A companion `compat.thinkingFormat` field (e.g. `deepseek`) corrects how the thinking payload travels on the wire per-gateway.

This is directly analogous to the `--reasoning-effort` flag ADR-013 already found necessary for the Unsloth/xLAM candidate — except here it's a per-model/per-route settings-file knob rather than a process CLI flag, which is arguably a cleaner fit for the profile-driven config this repo already uses.

## Q4 — System-prompt size risk: verified absent, by design (opposite of opencode's bug)

Checked directly rather than assumed. `docs/subsystems/skills.md` states the model-facing catalog "uses only model-invocable `name` and `description`, **never the body or absolute file path**." Full skill instructions load lazily through a `skill` tool call only when the model chooses to invoke a specific skill by name — the same lazy-load pattern Claude Code's own skill system uses, and the structural opposite of what broke opencode's `--auto` system prompt (which apparently enumerated full/thousands of skill entries into one ~282K-token prompt).

Default discovery roots are also scoped, not global: `<projectRoot>/.dsh/skills`, `<projectRoot>/.agents/skills`, then user-level `<dshHome>/skills` and `<agentsHome>/skills`. A deployment that deliberately points `custom`/`user-agents` roots at a directory with thousands of skills would still add proportional token overhead from names+descriptions, but that's a linear, bounded cost — not the same order of magnitude as opencode's full-content enumeration. This failure mode is not reproducible in dsh by architecture, not by luck.

## Q5 — Maturity/stability: developer preview, confirmed by evidence, and actively surfacing relevant bugs today

- **No stable release exists.** Every one of the 9 published tags is a prerelease: `dsh-v0.1.0-rc.7` (2026-08-17) through `dsh-v0.1.2-alpha.5` (2026-09-02 — the day of this evaluation). That's 9 releases in 16 days with no `1.0`/GA tag. `main`-adjacent alpha is the only option; there is nothing to pin that isn't itself explicitly labeled unstable.
- **GitHub Issues are disabled** on the repo (`hasIssuesEnabled: false`, confirmed via GraphQL). Support and bug triage happen only in Discussions, informally, with community members (not maintainers) answering — the #5293 response above was answered by a community user, not a DeepSeek maintainer, and states plainly "这属于产品设计取舍，不是我能替官方决定的事" ("this is a product design tradeoff, not mine to decide on the vendor's behalf").
- **Two fresh, open, directly-relevant bugs**, both surfaced in the last 24–48 hours of this evaluation:
  - [#5293](https://github.com/deepseek-ai/deepseek-harness/discussions/5293) (2026-09-01) — see Q1: `llm-deepseek` breaks third-party OpenAI-compatible gateways by design.
  - [#5466](https://github.com/deepseek-ai/deepseek-harness/discussions/5466) (2026-09-03, i.e. filed the day after this evaluation snapshot) — a turn where a reasoning model returns **pure chain-of-thought with no text and no tool call** ("容易出现于实验版模型 + 高推理" — "easy to trigger with experimental models + high reasoning") gets persisted as an assistant message with empty `content` and no `tool_calls`. On replay, the gateway 400s with `content or tool_calls must be set`, and **every subsequent turn in that session fails identically — the session is permanently poisoned**, unrecoverable without starting a new one. This is precisely the failure shape ADR-013 already worries about for high-reasoning-effort local models (the report explicitly says it's more likely at high `reasoningEffort`).
- No discussion specifically about local/self-hosted/Ollama/llama.cpp endpoint usage turned up in the 20 most recent Discussions searched — this would be uncharted territory for the team, not a validated path with prior art to lean on.

## Why "wait" and not "adopt behind a pin"

A version pin only helps if the pinned version is stable enough to sit still on; here every tag is explicitly `alpha`/`rc`, the two most relevant bugs found are both unresolved and were filed in the current release (`alpha.5`)/the day after, and Issues are disabled so there's no formal fix-tracking to watch. Pinning `alpha.5` would mean pinning to a version with a live, open, session-poisoning bug in the exact usage pattern (high reasoning effort) this team needs. The honest cost of adopting dsh right now is a second verification cycle spent on the harness's own bugs, not the model — the same shape of cost that opencode's skill-enumeration bug already extracted once this cycle.

## What would change this recommendation

- A tagged non-prerelease (`1.0.0` or similar) release.
- Either of the two bugs above (#5293, #5466) confirmed fixed and released.
- Direct evidence (a discussion, a maintainer note, or a first-party doc) that someone has run `llm-pi-ai` against a local `llama-server`/Ollama endpoint successfully — none was found in this pass.
