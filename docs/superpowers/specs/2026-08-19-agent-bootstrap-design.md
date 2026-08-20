# Validated local-agent bootstrap — design

Date: 2026-08-19
Status: Proposed, implements ADR-012 in full (all six transaction steps in one pass, not phased), prioritized ahead of the Linux port per user direction. Revised twice after external review: S-01 through S-13 incorporated (S-14 deferred as explicitly-endorsed follow-up hardening), then H24-01 through H24-10 incorporated (H24-07 caught a real bug in the S-06 revision: a failed bootstrap must never invalidate a different, still-valid session's published state; H24-09 caught that `ai-opencode` as first written would silently write into the user's real project tree).

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

A second review round (H24-01 through H24-10) prompted two more checks,
both live:

4. **The debug log never contains the literal `baseURL` string or port
   number.** Ran a second spike specifically grepping captured
   `--print-logs --log-level DEBUG` output for `12345`/`baseURL` (1479
   log lines captured): zero matches. Confirms H24-02's concern that
   "assert config path, provider, and model" doesn't by itself prove
   which *endpoint* was used. The fix is structural, not new logging
   infrastructure: each trial's workspace path already includes a
   fresh, disposable, uniquely-numbered directory (`$PID-<trial>`) that
   this contract itself creates and is the only place that trial's
   `-Endpoint` was ever written. Confirming *that exact path* was
   loaded (already proven observable) is sufficient proof of which
   endpoint config was active, since no other config could exist at
   that path — the uniqueness of the path is the correlation mechanism,
   not a string match on the URL itself.
5. **`opencode --help` has no `--config`/config-path override flag or
   documented env var either.** `.opencode/opencode.json` (project-
   scoped) and `~/.opencode/opencode.json` (global) are confirmed as
   the only two load-bearing locations. This matters for H24-09: there
   is no way to point a real interactive `ai-opencode` session's config
   at a location other than the user's actual project directory or
   their real global config, without either writing into their project
   (rejected, see `ai-opencode` below) or temporarily touching the
   global file.
6. **`tool-proxy/app/main.py` has no version identifier anywhere** —
   grepped directly, zero hits. H24-03's `proxyVersion` evidence-key
   component can't be observed as-is. Adding a `PROXY_VERSION`
   constant surfaced via `/health` is a small, in-scope addition to
   `tool-proxy`, cheaper and more useful than failing the whole
   contract closed for a field that's trivial to make observable.

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
   externally owned is reused without taking ownership of it and is
   never stopped by this transaction under any outcome; a proxy this
   transaction starts itself is tracked as session-owned (S-11). Full
   proxy lifecycle across the whole candidate loop (H24-06): if this
   run started the proxy and the current candidate ultimately fails
   both transports, the session-owned proxy is stopped before moving
   to the next candidate rather than left running for a model that
   didn't pass; if a later candidate then needs the proxy again, it is
   started fresh rather than assumed still there. If a candidate does
   pass via the session-owned proxy, it is kept running (not stopped)
   for `ai-opencode` to actually use. If every candidate is exhausted
   with no pass, any still-running session-owned proxy is stopped as
   part of the transaction's own cleanup — nothing this run started is
   ever left behind on overall failure. Both transports failing for a
   candidate moves to the next candidate model, not a hard stop.
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
   real project or `~`. The uniqueness of this path is itself load-
   bearing (see step 5's endpoint assertion below), not incidental.
2. Generate a fresh cryptographically random marker (16 bytes, hex)
   **per trial**, write it only into `seed.md` inside the workspace —
   never into the prompt (S-01: the first draft's prompt disclosed the
   expected marker text directly, so a model could pass without
   reading the file at all; confirmed as a real self-fulfilling-check
   bug, not a nitpick).
3. Write `$workspace\.opencode\opencode.json` (S-02, confirmed by the
   live spike above — a bare root `opencode.json` is not the
   load-bearing project-scoped path) as a **complete provider
   declaration**, not just `baseURL`/`model` (H24-01: `-m
   ollama/<model>` alone assumes a provider ID and npm package that
   are never actually declared). Same shape as the already-shipped
   `config/opencode.json.template` — `provider.<id>.npm`,
   `provider.<id>.name`, `provider.<id>.options.baseURL`, and a
   `models` map — with `<id>` and `options.baseURL` set from
   `-Endpoint` and `model` set from `-Model`. Reusing the proven
   template shape rather than a new minimal schema also means the
   live spike that validated it (see above) covers the real structure
   this contract writes, not a simplified stand-in. Fresh config per
   trial, never the user's own global/project config.
4. Run `opencode run --dir $workspace --print-logs --log-level DEBUG
   -m $Model "Read seed.md. Create output.md containing exactly the
   value after MARKER=. Do not access files outside this workspace.
   Reply exactly DONE."` (S-01's corrected prompt: the derived-value
   write is what actually proves the read happened, not a
   yes/no answer the model could guess). Explicit `--dir` and `-m`
   flags (S-03, confirmed no `--endpoint` flag exists so the base URL
   can only come from the config file written in step 3).
5. Assert all of: process exit success within the phase timeout
   (S-08); the captured debug log contains a `"loading config from
   <workspace>\.opencode\opencode.json"` line for *this exact trial's
   unique path* (S-07/H24-02 — proves OpenCode loaded this specific
   config and not a stale global one; since no other config was ever
   written to this unique path, and the debug log confirms no
   `baseURL` string is ever printed directly, the path's uniqueness
   *is* the endpoint-correlation mechanism, confirmed by a second live
   spike above rather than assumed) and the expected provider/model
   IDs; `output.md` exists and its content matches the marker
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
   before the first token, and skill-directory enumeration alone added
   several more) and `PerRunTimeoutSec` (default 45) for later trials
   once the model's already warm. A timeout's reported reason names
   the phase (backend unreachable / model loading / OpenCode init /
   tool execution / no completion) and the candidate, not a bare
   "timed out."

Overall verdict is pass only if `TrialCount` consecutive trials all
pass (S-09: default 3, a single pass is not proof against a stochastic
model — real added latency, already the natural cost of "prove a live
tool loop" and disclosed as such in Consequences below). Verdict,
trial count, and evidence are all recorded via the caller into the
capability registry.

`Start-AgentSession.ps1` enforces a `TotalBootstrapTimeoutSec` (H24-05,
default 600 — enough for several candidates × transports × trials on a
cold machine, generous rather than tight given this runs rarely, not
per-request) across the whole select/prove/decide loop, printing which
candidate/trial/transport is currently in progress rather than going
silent for minutes. Hitting the total budget stops with
`budget_exhausted` and whatever evidence was gathered before the cutoff
recorded, not a bare timeout with no context on how far it got.

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
  fails, rather than launching OpenCode against unverified state.

  **On success (H24-09):** confirmed live that `opencode` has no
  config-path override flag or env var — `.opencode/opencode.json`
  (project-scoped) and `~/.opencode/opencode.json` (global) are the
  only two load-bearing locations. Writing into the user's actual
  project directory just to launch a validated session was the first
  draft's design and is wrong: it mutates a real project tree as a
  side effect, and a file left behind by an interrupted session could
  end up accidentally committed. `ai-opencode` instead **stashes the
  user's real global `~/.opencode/opencode.json` (if any), writes the
  validated model/endpoint there for the duration of the session, and
  restores the original content on exit** — success, failure, or
  interrupt (PowerShell `try`/`finally`, matching `Stop-Process`-style
  cleanup already used elsewhere in this repo). This is the same
  stash/restore shape `ai-claude-on`/`ai-claude-off` already use for
  Claude Code (ADR-008), not a new pattern invented for this feature.
  `opencode` itself is then launched with `--dir <the user's actual
  cwd>` so file reads/writes happen in the user's real project as
  intended, while only the *config* is temporarily redirected through
  the global path. `-m <provider/model>` is still passed explicitly
  even though it's also in the temp global config, so a mismatch
  between the two is detectable rather than silently trusting one.

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

Every evidence-key component has a defined, real probe (H24-03 — the
first draft left this implicit, and one of the four doesn't even exist
yet):
- `modelDigest`: `ollama show <model> --json`, the `digest` field.
- `ollamaVersion`: `ollama --version` (or the equivalent field already
  surfaced by `/api/version`, whichever proves more stable in
  practice).
- `contextSettings`: `config/models.json`'s existing `contextWindow`
  field for the candidate — already-present data, not a new source.
- `opencodeVersion`: `opencode --version`, already used for the
  registry key today via the debug log's own version line.
- `proxyVersion` (endpoint-mode `proxy` only): a new `PROXY_VERSION`
  constant surfaced on `tool-proxy`'s `/health` response — confirmed
  live that no version identifier exists anywhere in
  `tool-proxy/app/main.py` today, so this is a small, in-scope
  addition, not a probe against something already there.

If any *mandatory* component for the current endpoint mode can't be
observed (e.g. `ollama --version` fails, or the proxy's `/health`
doesn't respond), the contract fails closed with reason
`evidence_unavailable` — it never publishes a registry entry or
`active-agent.json` built from an invented or default value for a
field the evidence key depends on.

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
`proxy.processStartedAt` is advisory only (H24-10) until S-14 lands —
it is not, by itself, proof of PID ownership (Windows PID reuse means
a timestamp alone can't distinguish "the process this session started"
from "a different process that happens to share a recycled PID and a
similar start time"). The command-line-marker identity check PR #16
already added remains the actual ownership proof; this field exists
for diagnostics, not as a security boundary.

Both files are written via same-directory temp file + validate +
atomic rename, restricted to the current user. The lockfile (H24-04)
guarding concurrent `ai-agent-start` runs is created atomically
(exclusive create, fails if it already exists — not a check-then-create
race), stores the owning `sessionId`/PID/start timestamp, waits with a
bounded retry budget, and reclaims a lock only when its recorded PID is
demonstrably dead (`Get-Process` finds nothing) — a live PID holding
the lock is never preempted, only waited on or given up on after the
bound. Release only succeeds when the caller's own `sessionId` matches
the lock's recorded owner, so one session can never release a lock it
doesn't hold.

**A failed bootstrap never touches a *different* session's published
state (H24-07 — the original design here was a real bug, not a
wording gap):** the first draft had any failure invalidate whatever
`active-agent.json` currently existed, which would let shell B's
exploratory `ai-agent-start` failure silently invalidate shell A's
still-valid, still-in-use session. The corrected rule is simpler than
the original, not more complex: `active-agent.json` is **only ever
written on a new success**, under the bootstrap lock, and a failure
writes nothing and touches no existing file at all. A prior unexpired
active state survives any number of unrelated failed bootstrap
attempts and is only ever superseded by a new one actually publishing
a pass.

## Testing

- `Invoke-CapabilityContract.ps1`'s workspace setup/teardown, marker
  generation, evidence-key construction, and JSON parsing get mocked
  pytest-style PowerShell unit tests
  (`scripts/Test-CapabilityContract.ps1`), asserting logic without
  actually invoking `opencode` — same reasoning as every other
  `Test-*.ps1` in this repo not depending on a live external process.
  Explicit coverage: candidate ordering, per-candidate failure
  reasons, direct-to-proxy fallback, no-proxy-needed-after-direct-pass,
  evidence-key changes on any input component, `evidence_unavailable`
  fail-closed behavior when a mandatory probe fails, expired vs.
  not-yet-expired registry entries, retryable (transient) vs.
  non-retryable (structural) failure classification, atomic-write
  recovery from a torn/partial file, atomic lock acquisition/stale-lock
  reclaim/ownership-checked release, concurrent `ai-agent-start`
  launches, proxy-ownership-scoped cleanup across a full multi-candidate
  run (direct-fail → proxy-fail → next-candidate-direct-pass, and
  full-candidate-exhaustion cleanup), a failed bootstrap never touching
  a different session's still-valid `active-agent.json`, and `-WhatIf`
  performing zero mutations.
- One real, live, full end-to-end run of `ai-agent-start` against this
  machine's actual local Ollama and installed `opencode` (confirmed
  present, v1.18.18; live spike above already reproduced the exact
  direct-transport failure this design routes around), reported with
  real output including the actual observed Ollama/OpenCode versions
  from the debug trace, not the requested/assumed ones. Per H24-08,
  this is a **PR acceptance requirement for the implementation**, not
  just a one-time build-session action: the successful run's sanitized
  contract evidence (config path loaded, provider/model, marker/derived
  file match, no out-of-workspace access) gets attached to that PR, so
  the live proof stays auditable after the fact rather than only
  asserted in a commit message.
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

1. `PROXY_VERSION` constant + `/health` exposure in
   `tool-proxy/app/main.py` (small, isolated, needed by evidence-key
   construction later — trivial to land and verify first).
2. State helpers: atomic read/write, atomic lockfile with stale-owner
   reclaim, `schemaVersion`, evidence-key builder (with real probes,
   `evidence_unavailable` fail-closed path), expiry, with their own
   unit tests — no live `opencode` dependency, can be fully verified
   first.
3. `Invoke-CapabilityContract.ps1` against direct-Ollama transport
   only, unit-tested, then the one required live run (this is the
   riskiest, least-previously-verified piece, so it goes early among
   the live-dependent work rather than last) — the run whose sanitized
   evidence gets attached to the PR per H24-08.
4. Proxy-fallback path: contract fails direct, passes via
   `Start-ToolProxy.ps1`; ownership-scoped cleanup verified across a
   full multi-candidate run, not just a single fail/pass pair.
5. `Start-AgentSession.ps1` wiring the full transaction together
   (select → start backend → prove → decide transport → publish),
   including the total-budget timeout and progress reporting.
6. `ai-agent-start` / `ai-opencode` in `profile-helpers.ps1`, including
   the global-config stash/restore for `ai-opencode` (H24-09), stale-
   state refusal, single-tool-call disclosure.
