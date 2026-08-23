# ADR-012: Validated local-agent bootstrap — one command, one source of truth

## Status
Phases A-G implemented and merged as of commit `e3a075b` (PR #29-#32). An independent retest at that same commit (2026-08-22) returned **FAIL** for the primary acceptance goal: see "Retest gaps" below for the open P0/P1 items. Treat the "Next step" section below as historical — implementation started despite it.

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

## Retest gaps (2026-08-22, commit `e3a075b`)

Independent retest verdict: **FAIL** for the primary coding-agent
acceptance goal — the normal path still serves models by size/install
state, not proven capability. Live-verified against this repo's
current code (Ollama 0.32.14, `qwen3-coder:30b`/`qwen2.5-coder:7b`
resident, OpenCode 1.18.18, RTX 5000 Ada 16GB available on this
machine, so live proof is possible here, unlike the reviewer's Linux
sandbox). P0 items block certification; sequence reflects real
dependencies (003 gates the cert 002 relies on; 004/006 feed the trace
003 checks; 005 is the only item safe to parallelize as new files).

| ID | Confirmed at HEAD | Required remedy | Status |
|----|---|---|---|
| AGENT-003 | Yes — `Start-AgentSession.ps1:258-266` computes `$fitState.CodingReady` and only appends to `$failureReasons`; `$contractPassed` (line 219/238) is never revised, so `$publishedCertificate` still gets built at line 271 even when `CodingReady=false`. | `codingReady = artifactFit AND transportFit AND harnessFit` must be the sole publish gate; persist fit dimensions; re-check live residency/VRAM before reusing a cached pass. | Fixed (#34, `46c4d6f`) |
| AGENT-004 | Yes — `Invoke-OpenCodeCapabilityContract.ps1:136` and `Invoke-PiCapabilityContract.ps1:62` both derive `UsedValidStructuredToolEvents` from "stdout does not contain a raw-JSON-looking tool object," not an observed tool-call/tool-result event pair. | Capture a structured trace (request-ID-correlated tool-call -> tool-result -> next turn) from the endpoint/proxy/harness; no stdout-absence inference. | Open |
| AGENT-002 | Yes — `agent-profile-helpers.ps1` has no `ai-agent-start`/`ai-opencode` wrapper; `ai-code`/`ai-switch` don't consume or invalidate `active-agent.json`. | Make `ai-agent-start`/`ai-opencode` the only coding entry points; gate `ai-code` and the Pi/worker path on an unexpired certificate; `ai-switch` invalidates it. | Open |
| AGENT-005 | Not yet re-checked this session. | Replace the read/write-marker fixture with: read spec -> break a test -> run allowlisted test -> parse failure -> one repair -> rerun to pass; 3 cold + 3 warm trials; structured trace required each round. | Open (needs confirmation) |
| AGENT-006 | Not yet re-checked this session. | Plan/apply model acquisition with confirmation + provenance; Airlock starts and health-checks its own proxy fallback instance rather than assuming one is already running. | Open (needs confirmation) |
| AGENT-001 | Not yet re-checked this session (original finding: `Start-AI.ps1` defaults to `qwen2.5-coder:7b`; `Select-BestCuratedModel` ranks by installed-state then size, not agent eligibility). | Separate chat-ready from coding-ready; auto-acquisition may download a candidate only, never publish it as agent-ready without the full live contract. | Open (needs confirmation) |

**AGENT-003 disclosed gap (added on merge of #34):** the fix scopes
`codingReady` gating to the Ollama runtime only — the runtime that can
actually measure free VRAM and residency today. `llama-server` and
`lmstudio` profiles still publish a certificate on harness-contract
pass alone, with no fit-state check, exactly as they did before this
fix (see the pre-existing "Only computable for Ollama today" comment
in `Start-AgentSession.ps1` that predates AGENT-003). An earlier round
of this fix made non-Ollama runtimes fail-closed unconditionally,
which broke the shipped `llama-server` profile outright — a live
regression, not a theoretical one — so it was reverted back to this
disclosed, documented gap rather than a silent one. Closing it for
real requires residency/VRAM measurement adapters for those runtimes
(tracked nowhere yet — needs its own follow-up item, not scoped here).

**AGENT-004 disclosed gaps:** the fix replaces stdout-absence inference
with positive observation of structured tool-use events, plus path-containment
workspace escape detection, verified live against OpenCode + Ollama. Three
gaps remain explicit (not hidden):
1. **Request-ID correlation sequencing** — code detects tool_use events but
   does not verify call/result ID pairing or turn order. Requires extracting
   ID field from real --format json output and cross-referencing events.
   Deferred to AGENT-007+ for full sequencing audit.
2. **Pi-worker contract path** — code is identical to OpenCode (shared JSON
   parsing logic, unit tests 18/18 pass) but has zero live evidence. Pi/Docker
   requires separate infrastructure not available in current verification
   environment. Deferred to AGENT-007 (Pi acceptance testing) for live trials.
3. **Workspace escape scenario** — path containment logic is correct but never
   triggered in live trials (successful models stay in-bounds). Requires
   adversarial instruction or model failure to observe `$outOfWorkspace=$true`.
   Deferred to security testing, out of AGENT-004 scope.

P1 items (AGENT-007..012) and AGENT-013 (RAG acceptance) are deferred
until the P0 set above is fixed and independently re-verified with a
live run, not just unit tests under mocks.
