# Validated local-agent bootstrap — design

Date: 2026-08-19
Status: Proposed, implements ADR-012 in full (all six transaction steps in one pass, not phased), prioritized ahead of the Linux port per user direction. Revised after external review (S-01 through S-13 incorporated as mandatory acceptance criteria; S-14 deferred as explicitly-endorsed follow-up hardening).

## Problem

See ADR-012 for the full context. Short version: `ai-start`,
`ai-tool-proxy-start`, model selection, and the OpenCode template are
four independently-correct, independently-green components that can
disagree with each other, so a user can have a healthy backend and
passing CI with no working local coding agent. `preferredLocalModel`
in `config/policies/provider-policy.json` is confirmed unused
(grepped `scripts/Get-ModelAcquisition.ps1` directly, zero hits), and
`supportsFunctionCalling` is a static boolean nobody re-verifies
against the actual model/Ollama/OpenCode versions currently installed.

## Live spike findings (grounding this revision)

Before writing this revision, ran a real `opencode run --dir <temp> --print-logs --log-level DEBUG -m ollama/qwen2.5-coder:7b` against this machine's actual Ollama, confirming three things the first draft got wrong or left unverified:

1. **`opencode run --help` has no `--endpoint`/`--base-url` flag at all.** Only `-m/--model` (format `provider/model`) and `--dir` (working directory). The provider endpoint can only come from a config file, confirming the reviewer's S-03 concern was real, not hypothetical.
2. **`--dir <path>` does drive config auto-discovery.** The debug log showed `"loading config from <path>\.opencode\opencode.json"` for the directory passed to `--dir`, confirming the reviewer's S-02 fix (`.opencode/opencode.json`, not a bare root `opencode.json`) actually works, and that `--dir` is the right mechanism rather than changing process CWD.
3. **`qwen2.5-coder:7b` talking directly to Ollama reproduced the exact raw-tool-call-as-text failure this session's tool-proxy work exists to fix**, unprompted, in this spike: the final output was `{"name": "read", "arguments": {"filePath": "C:/Users/veere/.agents/seed.md"}}` as literal text, never executed, with a hallucinated path pointing well outside the workspace. This is live, first-hand confirmation that (a) the direct-then-proxy fallback in step 4 is solving a real, currently-reproducible problem, not a theoretical one, and (b) the reviewer's S-10 concern (an agent asking for a path outside the workspace must be classified correctly, not treated as a proxy failure) is not a hypothetical edge case either.

Also checked `scripts/Start-AI.ps1`: it already has a `-Model` parameter,
defaulting to `qwen2.5-coder:7b`, with an existing code comment
confirming callers can pin it explicitly. The reviewer's S-04 doesn't
need a change to `Start-AI.ps1` itself, just a correct call site.

## Decision

Build `scripts/Start-AgentSession.ps1` (the transaction) and
`scripts/Invoke-CapabilityContract.ps1` (the capability proof it
depends on), plus two new `profile-helpers.ps1` functions,
`ai-agent-start` and `ai-opencode`. Full ADR-012 transaction in one
pass, unlike the Linux port's multiple independent subsystems, this is
a single pipeline, and a partial version would reintroduce exactly the
"looks configured but isn't" gap the ADR exists to close.

The capability proof shells out to **real `opencode run`** against a
disposable temp workspace, not an internal simulated tool loop. This is
a deliberate choice over the faster/cheaper internal-loop alternative,
because a fake loop could pass while OpenCode's own streaming parser
or config precedence still breaks in practice (this is exactly what
PROXY-005 flagged as unverified, and what the live spike above just
reproduced directly). This also means the separate "AGENT-003 Windows
acceptance test" both external reviews called out is not a distinct
future CI job: it's this same code path, run for real in this session
as part of building it.

## Components

### `scripts/Start-AgentSession.ps1` (new)

Mirrors `Start-AI.ps1`'s shape: audit logging via the same JSONL
pattern, structured console output, `-WhatIf`-compatible where it
takes destructive-ish actions (starting processes). Performs steps
1, 2, 4, 5 of ADR-012's transaction; step 3 is delegated to
`Invoke-CapabilityContract.ps1` (kept separate so the contract itself
is independently testable and reusable, matching the existing
`Start-AI.ps1`/`Get-ModelAcquisition.ps1` split in this repo).

1. **Select**: candidate list is
   `[preferredLocalModel] + localFallbackModels` from
   `provider-policy.json`, in that order, filtered to models actually
   present in `ollama list`. First candidate to pass the capability
   contract wins; if the whole list is exhausted with no pass, exit
   non-zero with every candidate's specific failure reason, never a
   generic "no model available."
2. **Start backend**: calls `Start-AI.ps1 -Model $candidate` (S-04) so
   the backend, the contract request, the audit log, and the eventual
   OpenCode invocation all name the exact same model, not four
   independently-arrived-at guesses. Reads `.active-port.json` for the
   live port, same as `tool-proxy` already does.
3. **Prove capability**: for the current candidate, check
   `state/capability-registry.json` first for a fresh entry keyed on
   the full evidence key (S-05, schema below); on a fresh pass, skip
   straight to step 4/5. On a fresh fail, skip this candidate/transport
   combination entirely (don't retry a known-bad combination this
   run). Otherwise call `Invoke-CapabilityContract.ps1` and record the
   result.
4. **Decide transport**: run the contract against direct Ollama
   first; if it fails, start the tool-proxy (`Start-ToolProxy.ps1`,
   reusing its existing identity-safe start/reuse logic from PR #16)
   and re-run the contract through it. A proxy already healthy and
   externally owned is reused without taking ownership of it; a proxy
   this transaction starts itself is tracked as session-owned (S-11)
   so cleanup on failure only ever stops what this run actually
   started. Both transports failing moves to the next candidate model,
   not a hard stop.
5. **Publish state**: write `state/active-agent.json` only after a
   candidate passes, using atomic write-then-rename (S-06).
6. **Launch**: this step lives in `ai-opencode`, not
   `Start-AgentSession.ps1` itself, so `ai-agent-start` and
   `ai-opencode` can be used independently: e.g. scripting scenarios
   that want the validated state without immediately launching an
   interactive OpenCode session.

`-WhatIf` (S-12): performs step 1's filtering and prints the candidate
order and planned direct/proxy sequence only. It never starts a
backend or proxy, never runs `opencode`, never writes a registry entry
or `active-agent.json`. Side-effecting by nature is exactly why this
needs to be stated explicitly rather than left implied.

If the winning combination is on a harness/model profile known to only
support single-tool-call turns (i.e., PROXY-002's parallel-tool-call
truncation applies), `ai-agent-start`'s success output says so
explicitly (S-13) — a visible, permanent caveat on every successful
run until PROXY-002 itself is fixed, not a one-time warning easy to
miss or forget.

### `scripts/Invoke-CapabilityContract.ps1` (new)

Takes `-Model`, `-Endpoint`, `-TrialCount` (default 3, S-09), returns a
pass/fail verdict, per-trial results, and a bounded evidence summary.
Mechanics, run once per trial:

1. Create a disposable temp workspace
   (`$env:TEMP\air-agent-contract-$PID-<trial>`), never the user's
   real project or `~`.
2. Generate a fresh cryptographically random marker (16 bytes, hex)
   **per trial**, write it only into `seed.md` inside the workspace —
   never into the prompt (S-01: the first draft's prompt disclosed the
   expected marker text directly, so a model could pass without
   reading the file at all; confirmed as a real self-fulfilling-check
   bug, not a nitpick).
3. Write `$workspace\.opencode\opencode.json` (S-02, confirmed by the
   live spike above — a bare root `opencode.json` is not the
   load-bearing project-scoped path) pointing `baseURL` at `-Endpoint`
   and `model` at `-Model`. Fresh config per trial, never the user's
   own global/project config.
4. Run `opencode run --dir $workspace --print-logs --log-level DEBUG
   -m $Model "Read seed.md. Create output.md containing exactly the
   value after MARKER=. Do not access files outside this workspace.
   Reply exactly DONE."` (S-01's corrected prompt: the derived-value
   write is what actually proves the read happened, not a
   yes/no answer the model could guess). Explicit `--dir` and `-m`
   flags (S-03, confirmed no `--endpoint` flag exists so the base URL
   can only come from the config file written in step 3).
5. Assert all of: process exit success within the phase timeout
   (S-08); the captured debug log contains the expected config path,
   provider, and model (S-07 — this is what actually proves OpenCode
   loaded *this* config and not a stale global one, which output alone
   can't show); `output.md` exists and its content matches the marker
   generated in step 2 exactly; no tool call or file access was
   requested outside the workspace (S-10 — a request for an outside
   path is classified as `permission_scope`/`path_resolution` and
   fails this trial, it is not treated as a transport/proxy defect,
   and workspace-boundary denial is never weakened to make a trial
   pass).
6. Clean up the temp workspace unconditionally (`finally`, success or
   failure) before returning.
7. Timeouts are phase-classified (S-08), not one fixed 60s: a
   configurable `ColdStartTimeoutSec` (default 90, allowing for model
   load — the live spike above took ~9s just past config loading
   before the first token) and `PerRunTimeoutSec` (default 45) for
   later trials once the model's already warm. A timeout's reported
   reason names the phase (backend unreachable / model loading /
   OpenCode init / tool execution / no completion) and the candidate,
   not a bare "timed out."

Overall verdict is pass only if `TrialCount` consecutive trials all
pass (S-09: default 3, a single pass is not proof against a stochastic
model — real added latency, already the natural cost of "prove a live
tool loop" and disclosed as such in Consequences below). Verdict,
trial count, and evidence are all recorded via the caller into the
capability registry.

### `profile-helpers.ps1` additions

- `ai-agent-start`: calls `Start-AgentSession.ps1`, prints the
  winning model/endpoint or the full per-candidate failure list, and
  the single-tool-call caveat when applicable (S-13).
- `ai-opencode`: checks `active-agent.json` exists, is not expired
  (`expiresAt`, S-06), is not `invalidatedAt`-marked, matches the
  current `schemaVersion`, and that its recorded proxy PID (if any) is
  still alive and identity-verified. `Test-ToolProxyProcessIdentity`
  (the command-line-marker check PR #16 added) currently lives
  duplicated inside `Start-ToolProxy.ps1` and `Stop-ToolProxy.ps1`,
  both scripts with side-effecting top-level code, not safe to
  dot-source from `profile-helpers.ps1` just to reach one function.
  `ai-opencode` gets its own copy of the same check instead, matching
  this repo's existing choice (PR #16 already duplicated it twice
  rather than extracting a shared module for two call sites) over
  introducing a new shared-module abstraction for a third. Refuses
  with a clear message and a pointer to `ai-agent-start` if any check
  fails, rather than launching OpenCode against unverified state. On
  success, launches `opencode --dir <cwd> -m <provider/model>` with
  the model from state passed explicitly, config supplied the same
  `.opencode/opencode.json` way the contract itself uses, not relying
  on any stale global/project config's own defaults.

## State schemas

`state/capability-registry.json` (S-05, S-06):
```json
{
  "schemaVersion": 1,
  "entries": {
    "sha256:<evidence-key>": {
      "provider": "ollama",
      "modelTag": "qwen3-coder:30b",
      "modelDigest": "sha256:<digest>",
      "endpointMode": "proxy",
      "endpointIdentity": "http://127.0.0.1:12347/v1",
      "ollamaVersion": "<observed>",
      "opencodeVersion": "1.18.18",
      "contractVersion": "1",
      "contextSettings": { "numCtx": 32768 },
      "verdict": "pass",
      "trialCount": 3,
      "passedTrials": 3,
      "provenAt": "2026-08-19T22:00:00Z",
      "expiresAt": "2026-08-19T22:05:00Z",
      "reason": null,
      "evidenceSummary": "redacted and bounded"
    }
  }
}
```
`evidence-key` is `SHA256(contractVersion, provider, modelTag,
modelDigest, endpointMode, endpointIdentity, ollamaVersion,
opencodeVersion, contextSettings)` — used as the lookup key so it's
collision-safe and version-stable, with every component it was built
from duplicated as plain fields in the entry for human debugging (the
hash alone would make cache invalidation and debugging harder, which
is exactly what this schema is meant to avoid). Pass and fail entries
get separate TTLs (a pass is trusted for the `expiresAt` window above;
a fail is intentionally shorter-lived by default, so a transient
model-load hiccup doesn't become a long-lived false block) — both
overridable via `-ForceVerify`/`-NoCache` on `Start-AgentSession.ps1`.

`state/active-agent.json` (S-06):
```json
{
  "schemaVersion": 1,
  "sessionId": "uuid",
  "model": "qwen3-coder:30b",
  "modelDigest": "sha256:<digest>",
  "endpointMode": "proxy",
  "endpoint": "http://127.0.0.1:12347/v1",
  "backendPort": 12345,
  "proxy": {
    "pid": 1234,
    "processStartedAt": "2026-08-19T22:00:00Z",
    "port": 12347,
    "startedBySession": true
  },
  "capabilityEvidenceKey": "sha256:<evidence-key>",
  "provenAt": "2026-08-19T22:00:00Z",
  "expiresAt": "2026-08-19T22:05:00Z",
  "invalidatedAt": null
}
```
Both files are written via same-directory temp file + validate +
atomic rename, restricted to the current user, with a simple lockfile
(retry-with-backoff, not an OS mutex primitive — this repo has no
existing cross-platform locking dependency and one isn't warranted for
a single-user, mostly-sequential CLI) guarding concurrent
`ai-agent-start` runs. A bootstrap that fails after a prior run
published state invalidates (`invalidatedAt`) rather than deletes that
state, so a stale "ready" claim is never left silently trusted.

## Testing

- `Invoke-CapabilityContract.ps1`'s workspace setup/teardown, marker
  generation, evidence-key construction, and JSON parsing get mocked
  pytest-style PowerShell unit tests
  (`scripts/Test-CapabilityContract.ps1`), asserting logic without
  actually invoking `opencode` — same reasoning as every other
  `Test-*.ps1` in this repo not depending on a live external process.
  Explicit coverage: candidate ordering, per-candidate failure
  reasons, direct-to-proxy fallback, no-proxy-needed-after-direct-pass,
  evidence-key changes on any input component, expired vs.
  not-yet-expired registry entries, retryable (transient) vs.
  non-retryable (structural) failure classification, atomic-write
  recovery from a torn/partial file, proxy-ownership-scoped cleanup,
  stale `active-agent.json` refusal, and `-WhatIf` performing zero
  mutations.
- One real, live, full end-to-end run of `ai-agent-start` against this
  machine's actual local Ollama and installed `opencode` (confirmed
  present, v1.18.18; live spike above already reproduced the exact
  direct-transport failure this design routes around), reported with
  real output including the actual observed Ollama/OpenCode versions
  from the debug trace, not the requested/assumed ones.
- Audit log and any persisted evidence store sanitized, bounded
  summaries only — no prompts, full model transcripts, or secrets ever
  written to disk.
- Not built this pass: a CI job running any of this. `opencode`,
  Ollama, and a real model are not available in the GitHub Actions
  Windows runner this repo's CI currently uses. Same disclosed gap
  ADR-012 itself already named (self-hosted runner requirement), not a
  new one introduced here.

## Non-goals

- No change to `ai-start`, `ai-tool-proxy-start`, or direct `opencode`
  invocation. All three keep working exactly as before for anyone not
  using `ai-agent-start`.
- No CI acceptance job (see Testing above).
- No harness beyond OpenCode. Pi.dev/aider/jcode integration is a
  future extension, not scoped here: `Invoke-CapabilityContract.ps1`
  is written OpenCode-specific rather than prematurely generalized for
  harnesses this pass doesn't test against.
- PROXY-002 (parallel tool calls) is not fixed here, per ADR-012's own
  scope cut. The capability contract only exercises single-tool-call
  paths, and a successful run's output discloses that limitation
  explicitly (S-13) rather than staying silent about it.
- S-14 (proxy PID start-time + instance-nonce ownership proof, beyond
  the command-line-marker identity check PR #16 already added):
  explicitly endorsed by the reviewer as follow-up hardening, not a
  bootstrap-MVP blocker. Not built this pass.

## Suggested implementation order

1. State helpers: atomic read/write, lockfile, `schemaVersion`,
   evidence-key builder, expiry/invalidation, with their own unit
   tests — no live `opencode` dependency, can be fully verified first.
2. `Invoke-CapabilityContract.ps1` against direct-Ollama transport
   only, unit-tested, then the one required live run (this is the
   riskiest, least-previously-verified piece, so it goes first among
   the live-dependent work rather than last).
3. Proxy-fallback path: contract fails direct, passes via
   `Start-ToolProxy.ps1`; ownership-scoped cleanup verified against a
   session-started proxy and, separately, a pre-existing one that must
   survive.
4. `Start-AgentSession.ps1` wiring the full transaction together
   (select → start backend → prove → decide transport → publish).
5. `ai-agent-start` / `ai-opencode` in `profile-helpers.ps1`, stale-
   state refusal, single-tool-call disclosure.
