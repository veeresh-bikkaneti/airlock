# Validated local-agent bootstrap — design

Date: 2026-08-19
Status: Proposed, implements ADR-012 in full (all six transaction steps in one pass, not phased), prioritized ahead of the Linux port per user direction.

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
PROXY-005 flagged as unverified). This also means the separate
"AGENT-003 Windows acceptance test" both external reviews called out
is not a distinct future CI job: it's this same code path, run for
real in this session as part of building it.

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
2. **Start backend**: calls `Start-AI.ps1` (unchanged), reads
   `.active-port.json` for the live port, same as `tool-proxy` already
   does.
3. **Prove capability**: for the current candidate, check
   `state/capability-registry.json` first (see schema below); if no
   fresh entry exists for the exact
   `model:endpoint-mode:ollama-version:opencode-version` key, call
   `Invoke-CapabilityContract.ps1` and record the result.
4. **Decide transport**: run the contract against direct Ollama
   first; if it fails, start the tool-proxy (`Start-ToolProxy.ps1`,
   reusing its existing identity-safe start/reuse logic from PR #16)
   and re-run the contract through it. Both failing moves to the next
   candidate model, not a hard stop. A model that fails on the
   current backend might still be worth trying differently, but a
   model that fails both transports is genuinely not viable right now.
5. **Publish state**: write `state/active-agent.json` only after a
   candidate passes.
6. **Launch**: this step lives in `ai-opencode`, not
   `Start-AgentSession.ps1` itself (see below), so `ai-agent-start` and
   `ai-opencode` can be used independently: e.g. CI or scripting
   scenarios that want the validated state without immediately
   launching an interactive OpenCode session.

### `scripts/Invoke-CapabilityContract.ps1` (new)

Takes `-Model`, `-Endpoint` (direct Ollama or proxy URL), returns a
pass/fail verdict plus a reason string. Mechanics:

1. Create a disposable temp workspace (`$env:TEMP\air-agent-contract-$PID`),
   never the user's real project or `~`.
2. Seed it with a known file, `seed.md`, fixed content the contract
   knows in advance (so "did the read actually work" is checkable
   against a known-good answer, not just "did it not error").
3. Write a scoped, temporary `opencode.json` in that workspace
   pointing `baseURL` at `-Endpoint` and `model` at `-Model`, a fresh
   config per run, not the user's own global/project config, so this
   never reads or clobbers real user settings.
4. Run `opencode run "Read seed.md and reply with exactly the word
   CONFIRMED if it contains the phrase '<fixed marker>'."`, a
   deterministic, checkable read-path assertion, same "ask for exactly
   one word" pattern `docs/08-Agent-CLI-Setup-Guide.md`'s own verify
   steps already use for exactly this reason (smallest possible proof,
   nothing else to misread).
5. Run a second `opencode run` asking it to write a new file,
   `output.md`, with fixed content; verify the file actually exists on
   disk afterward with that content: the write half of ADR-012's
   "temporary-workspace read/write."
6. Clean up the temp workspace unconditionally (success or failure)
   before returning.
7. Verdict is pass only if both the read and the write assertions
   succeed; any process error, timeout (60s per `opencode run` call,
   generous given `docs/08`'s own live tests sometimes waited on model
   load), or wrong output is fail, with the specific reason preserved
   for the caller to report.

### `profile-helpers.ps1` additions

- `ai-agent-start`: calls `Start-AgentSession.ps1`, prints the
  winning model/endpoint or the full failure list.
- `ai-opencode`: checks `active-agent.json` exists, is newer than a
  short TTL (5 minutes, long enough to not re-run the contract on
  every single invocation in a work session, short enough that a
  stale state from an hour-old session doesn't get trusted), and that
  its recorded proxy PID (if any) is still alive and identity-verified.
  `Test-ToolProxyProcessIdentity` (the command-line-marker check PR #16
  added) currently lives duplicated inside `Start-ToolProxy.ps1` and
  `Stop-ToolProxy.ps1`, both scripts with side-effecting top-level
  code, not safe to dot-source from `profile-helpers.ps1` just to reach
  one function. `ai-opencode` gets its own copy of the same five-line
  check instead, matching this repo's existing choice (PR #16 already
  duplicated it twice rather than extracting a shared module for two
  call sites) over introducing a new shared-module abstraction for a
  third. Refuses
  with a clear message and a pointer to `ai-agent-start` if any check
  fails, rather than launching OpenCode against unverified state. On
  success, launches `opencode` with the model/endpoint from state
  passed explicitly, not relying on any config file's own defaults.

## State schemas

`state/capability-registry.json`:
```json
{
  "devstral-small-2:24b|direct|0.14.2|1.18.18": {
    "verdict": "pass",
    "provenAt": "2026-08-19T22:00:00Z"
  },
  "qwen2.5-coder:7b|proxy|0.14.2|1.18.18": {
    "verdict": "fail",
    "reason": "write assertion: output.md not created within 60s",
    "provenAt": "2026-08-19T22:01:30Z"
  }
}
```

`state/active-agent.json` (per ADR-012):
```json
{
  "model": "devstral-small-2:24b",
  "endpointMode": "direct",
  "endpoint": "http://127.0.0.1:12345/v1",
  "proxyPid": null,
  "proxyPort": null,
  "capabilityVerdict": "pass",
  "provenAt": "2026-08-19T22:00:00Z"
}
```

## Testing

- `Invoke-CapabilityContract.ps1`'s workspace setup/teardown and JSON
  parsing get mocked pytest-style PowerShell unit tests
  (`scripts/Test-CapabilityContract.ps1`, matching this repo's
  established self-test pattern), asserting the pass/fail logic
  without actually invoking `opencode`, same reasoning as every other
  `Test-*.ps1` in this repo not depending on a live external process.
- One real, live, full end-to-end run of `ai-agent-start` against this
  machine's actual local Ollama and installed `opencode` (confirmed
  present, v1.18.18), reported with real output, not a claimed result.
  Same verification standard the tool-proxy work used earlier this
  session.
- Not built this pass: a CI job running any of this. `opencode`,
  Ollama, and a real model are not available in the GitHub Actions
  Windows runner this repo's CI currently uses. This is the same
  disclosed gap ADR-012 itself already named (self-hosted runner
  requirement), not a new one introduced here.

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
  paths.
