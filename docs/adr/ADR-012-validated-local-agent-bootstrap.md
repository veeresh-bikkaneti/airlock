# ADR-012: Validated local-agent bootstrap — one command, one source of truth

## Status
Proposed. Not yet implemented. Requires its own brainstorm/spec pass before implementation (see "Next step" below): this ADR records the decision to build it and why, not an implementation plan.

## Context

Two independent reviews of the tool-proxy hardening work (PR #16,
`8c42bd0`) reached the same conclusion from different angles. The
hardening fixes themselves (PROXY-001/003/004, DEPLOY-001) are
confirmed real and confirmed fixed, both reviews verified this
independently, one from source + CI signal, and this repo's own TDD
process before merging. That is not in question.

What both reviews separately flagged is that fixing proxy-level bugs
does not fix the actual user-facing failure mode: **a user can have a
healthy Ollama endpoint, a passing CI build, and a non-working local
coding agent, all at the same time.** The cause is not a single
component being broken: it's that five independently-correct
components can disagree with each other:

- `ai-start` chooses/adopts an Ollama backend and writes
  `.active-port.json`.
- `ai-tool-proxy-start` is a **separate, manual, opt-in** command that
  the default `opencode.json.template` silently depends on (it
  hardcodes port `12347`, the proxy's port, not Ollama's).
- Model selection (`Get-ModelAcquisition.ps1`'s
  `Select-BestCuratedModel`) picks based on installed-model preference
  and a static `supportsFunctionCalling` boolean in `models.json`, and it
  does not consume `provider-policy.json`'s `preferredLocalModel`, and
  a boolean can't prove a model reliably completes a multi-turn tool
  loop, only that someone once judged it capable in principle.
- The OpenCode template's own `model` field is a third, independent
  default (`ollama/devstral-small-2:24b`), which can disagree with
  whichever model `ai-start` actually picked.
- Nothing validates any of this against a real tool-call round trip
  before the user starts working. CI proves the proxy translates
  *mocked* tool calls; it does not prove a real local model can
  read a file, get a result back, and finish a task.

Each piece reports its own "green" independently. None of them owns
the actual question a user cares about: **can this machine build an
app right now?**

## Decision

Build `ai-agent-start` (plus an `ai-opencode` wrapper) as the single
transactional entry point for local agentic coding, replacing the
current pattern of "run several unrelated commands and hope they
agree." This is additive: `ai-start`, `ai-tool-proxy-start`, and
direct `opencode` invocation all keep working exactly as they do
today for users/scripts that don't need the agent-specific guarantee.

`ai-agent-start` performs one transaction, in order, and refuses to
proceed past any failed step rather than degrading silently:

1. **Select**: choose a model only from combinations with a current,
   passing capability verdict (see "Capability verdict" below). If
   none qualify, stop and say so; never silently fall back to an
   unvalidated model.
2. **Start backend**: start or verify Ollama, recording the exact
   model, endpoint, and version actually active.
3. **Prove capability**: run a short, real tool contract: a
   structured tool call, a result-return turn, and a temporary-
   workspace read/write. This is what makes "capability verdict" mean
   something more than a hand-maintained boolean.
4. **Decide transport**: try direct Ollama first; if the contract
   fails direct but passes through the tool-proxy, use the proxy
   automatically (starting it if needed). If neither passes, stop.
5. **Publish state**: write `state/active-agent.json` (provider,
   model + exact tag/digest, endpoint, proxy PID/port if used,
   capability verdict, timestamp), written only after every prior
   step passed, so its mere existence is itself a claim worth trusting.
6. **Launch**: `ai-opencode` reads that file and passes an explicit
   `--model`/endpoint to OpenCode. It refuses to launch OpenCode
   against missing, stale, or dead-proxy state rather than connecting
   to something that looks configured but isn't.

### Capability verdict (replaces the static boolean)

`config/models.json`'s `supportsFunctionCalling: true/false` becomes
the *seed* for a capability registry keyed by model digest + Ollama
version + OpenCode version + endpoint mode (direct/proxy) + context
size, not the final word. A model only becomes eligible for agent mode
once step 3 above has actually passed for that exact combination.
Passing once does not mean passing forever. A version bump on either
side invalidates the prior verdict.

### What this explicitly does not change

- Direct Ollama use outside an agent harness (plain chat completions,
  `ai-code`/aider's `--file` pattern) is unaffected: it doesn't
  declare tools, so none of this applies to it.
- `PROXY-002` (only the first of multiple parallel tool calls is
  preserved) is not fixed by this ADR. Until it is, the capability
  contract in step 3 should test single-tool-call reliability only,
  and the supported OpenCode profile should explicitly disable
  parallel tool calls rather than silently losing the rest, a stated
  limitation beats a silent one, consistent with every other
  disclosed-gap decision in this codebase (`hermes-container/README.md`,
  Phase 1 of ADR pending for the Linux port).
- vLLM is not brought into scope here. It stays exactly as
  `tool-proxy/app/main.py` already documents it (unverified for tool
  calling), and should be marked `local-limited` for agent mode until
  it separately earns a capability verdict of its own.

## Consequences

**Positive**
- Five independently-green signals collapse into one user-relevant
  answer: "local agent ready" or a precise, actionable reason it isn't.
- A wrong-model-silently-serving-requests failure (the actual
  originally-reported symptom this session's tool-proxy work started
  from) becomes structurally impossible: `active-agent.json` cannot
  exist for a combination that never passed the contract.
- Capability claims stop being a point-in-time human judgment
  (`models.json`'s boolean) and become a machine-checked, re-verifiable
  fact tied to the exact versions in play.

**Negative**
- `ai-agent-start` adds real startup latency (a live tool-call round
  trip) compared to today's instant `ai-start`. Acceptable for an
  agent-specific entry point that only runs when a user actually wants
  to code with an agent, not for the general-purpose `ai-start` path.
- The capability registry is new persistent state
  (`state/capability-registry.json` or similar) that needs its own
  staleness/invalidation handling, a smaller version of the same
  "state can drift from reality" problem this ADR exists to solve
  elsewhere, so its own design needs to take that seriously rather
  than reintroduce it one layer up.
- Real acceptance testing (AGENT-003 from both reviews: a Windows
  self-hosted job that runs read → write → test in a disposable
  workspace via a pinned model) requires CI infrastructure this repo
  does not currently have (a self-hosted runner with Ollama installed).
  That is a real cost to scope honestly in the implementation plan, not
  hand-waved as "add a CI job."

## Next step

This ADR records the *decision*, not a design. Per this repo's
brainstorming process, "new orchestration subsystem coordinating
several existing components" is architectural-path work: it needs its
own clarifying-questions → approaches → sectioned design → spec →
review cycle before any code is written, the same process the Linux
port spec (`docs/superpowers/specs/2026-08-19-linux-port-design.md`)
just went through. Not started as of this ADR.
