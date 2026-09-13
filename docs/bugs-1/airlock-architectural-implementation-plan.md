# Airlock — Architectural Implementation Plan

**Version:** 1.0
**Date:** 2026-08-12
**Repo:** `veeresh-bikkaneti/airlock`
**Author basis:** Post-incident analysis of a ~2-hour Claude Code outage plus one failed `ai-start` → `ai-code` session

---

## 1. Why this document exists

On 2026-08-12, Claude Code became completely unusable on the development machine. Every request returned:

```
Connection refused — a firewall or proxy may be blocking it (ConnectionRefused)
```

Two hours of diagnosis eliminated firewall rules, corporate proxies, `netsh winhttp` settings, malformed JSON in three separate settings files, plugin hooks, and agent-description token limits before the actual cause surfaced: `ANTHROPIC_BASE_URL` was set to `http://127.0.0.1:8787`, a port with no listener.

**Airlock did not cause this incident.** The writer was Headroom, a separate context-optimization proxy whose Docker deployment had stopped with `Supervisor: none`. Airlock uses port 12345, not 8787.

But the investigation surfaced two things that matter:

1. **Airlock's documented Claude Code setup uses the identical mechanism** — an unconditional, persistent `ANTHROPIC_BASE_URL` redirect with no liveness guard and no teardown. It would produce the identical outage the first time `ai-stop` ran or the machine rebooted. This is a latent defect, not a hypothetical one.

2. **The local fallback path does not currently work at all**, for reasons unrelated to the outage — model selection sizes against the wrong resource, and `ai-code` never reaches the local endpoint.

The stated purpose of the platform is to keep work moving when the cloud model is unavailable. Right now, it is more likely to *cause* unavailability than to relieve it.

---

## 2. The failure class

This machine has at least four tools that independently mutate the same global surfaces:

| Tool | Mutates | Port |
|---|---|---|
| Airlock | `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OLLAMA_HOST` | 12345 |
| Headroom | `ANTHROPIC_BASE_URL`, Claude MCP servers, Claude settings hooks | 8787 |
| tokensave | Claude MCP servers, permissions, hooks, prompt rules | — |
| ruflo | `.claude/agents/`, `.claude/settings.json`, `.claude/helpers/` | — |

None of them declares ownership, checks for an existing value, verifies its target is alive, or reverses itself on shutdown. They write to process scope, user scope, and project config files interchangeably.

The consequence is that a failure in **any one** of them silently disables Claude Code for **all** projects on the machine, and presents an error message that names none of them.

Airlock cannot fix Headroom. But airlock is the user's own platform, it is the tool whose explicit job is managing local model routing, and it is therefore the correct place to be **defensive about the whole class**. The principles below follow from that.

---

## 3. Architectural principles

These are binding on all work below. A PBI that violates one is not done.

**P1 — Never mutate what you do not own.**
Every environment variable or config-file edit airlock makes is recorded in a mutation ledger with the prior value. Teardown reverses exactly those mutations and nothing else. Airlock never blind-deletes a variable it did not set.

**P2 — Never route to an endpoint you have not just health-checked.**
Setting a base URL is a claim that the endpoint works. That claim is verified at the moment it is made, not assumed from a prior startup.

**P3 — Session scope by default; persistent scope only on explicit opt-in.**
Airlock does not write `User` or `Machine` scope environment variables without the user asking for it in that specific invocation. Persistent scope survives every debugging technique a user will reach for, which is exactly why it is the wrong default.

**P4 — Every mutation is reversible by a single documented command.**
The existing `ai-memory-on` / `ai-memory-off` pair is the correct shape. Extend it.

**P5 — Fit is computed against the binding constraint.**
For GPU inference the binding constraint is VRAM, not system RAM. Selecting on the non-binding resource produces a model that technically loads and is unusably slow.

**P6 — Failures name themselves.**
Any error that leaves the user unable to work must state which component failed, what it was trying to reach, and the exact command to diagnose or reverse it. "Connection refused" with no attribution cost two hours.

**P7 — Documentation claims are tested.**
The README currently states that `ai-code` passes `--openai-api-base`. It does not. A claim in the README that no test covers is a claim that will drift.

---

## 4. Epic map

```
EPIC A — Environment governance        (AIR-1 … AIR-5)   ← foundational, unblocks trust
EPIC B — Local backend correctness     (AIR-6 … AIR-9)   ← makes the fallback actually work
EPIC C — Observability & diagnosis     (AIR-10 … AIR-13) ← makes failures self-explaining
EPIC D — Fallback contract             (AIR-14 … AIR-16) ← makes the feature honest
```

**Critical path:** AIR-6 → AIR-7 → AIR-2 → AIR-10. Those four alone move the platform from "broken" to "usable."

---

# EPIC A — Environment governance

*Goal: airlock can safely coexist with Headroom, tokensave, ruflo, and anything else that mutates agent-CLI configuration — and can never be the reason a user's cloud tooling stops working.*

---

## AIR-1 — Mutation ledger

**Problem.** Airlock sets environment variables and edits config files with no record of what it changed or what was there before. Teardown is therefore impossible to do safely: blind-deleting `ANTHROPIC_BASE_URL` on `ai-stop` would clobber Headroom's value if Headroom set it.

**Design.**

New file: `~/.ai-platform/state/owned-mutations.json`

```json
{
  "schema": "airlock.mutations/v1",
  "sessionId": "2026-08-12T14:22:01Z",
  "mutations": [
    {
      "kind": "env",
      "name": "ANTHROPIC_BASE_URL",
      "scope": "Process",
      "wroteValue": "http://127.0.0.1:12345",
      "priorValue": null,
      "priorPresent": false,
      "at": "2026-08-12T14:22:03Z",
      "reason": "ai-start: route Claude Code to local Ollama"
    },
    {
      "kind": "file",
      "path": "C:\\Users\\veere\\.aider.conf.yml",
      "backupPath": "C:\\Users\\veere\\.ai-platform\\state\\backups\\2026-08-12T142203Z\\.aider.conf.yml",
      "at": "2026-08-12T14:22:04Z",
      "reason": "ai-start: point aider at local endpoint"
    }
  ]
}
```

**Acceptance criteria.**
- [ ] Every env-var write performed by any airlock script goes through a single `Set-OwnedEnv` helper that appends to the ledger before writing.
- [ ] Every config-file edit goes through a single `Edit-OwnedFile` helper that takes a timestamped backup into `state/backups/` and appends to the ledger.
- [ ] The ledger records `priorPresent` distinctly from `priorValue: null` — "was unset" and "was set to empty" must be distinguishable, because they reverse differently.
- [ ] `Restore-OwnedMutations` reverses every ledger entry: restores prior values where `priorPresent` is true, removes the variable where it is false, and restores file backups byte-for-byte.
- [ ] Reversal is idempotent — running it twice is safe and the second run is a no-op.
- [ ] If a current value no longer matches `wroteValue`, reversal **skips that entry and warns** rather than overwriting. Someone else changed it after airlock did; airlock does not own it any more.
- [ ] Ledger writes are atomic (write-temp-then-move), so a crash mid-write cannot corrupt it.

**Verification.**
```powershell
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:9999"   # simulate a foreign tool
ai-start
ai-stop
$env:ANTHROPIC_BASE_URL   # MUST still be http://127.0.0.1:9999, not empty
```

**Non-goals.** Not a general config-management system. Ledger covers only mutations airlock itself performs.

---

## AIR-2 — Liveness-guarded routing

**Problem.** Airlock's documented Claude Code setup sets `ANTHROPIC_BASE_URL` unconditionally. Nothing verifies the endpoint is alive at the moment of writing, and nothing re-checks later. This is the exact shape of the Headroom outage.

**Airlock already has the correct pattern** in `profile-helpers.ps1`:

```powershell
$proxyCheck = Test-NetConnection -ComputerName 127.0.0.1 -Port 8787 -WarningAction SilentlyContinue
if ($proxyCheck.TcpTestSucceeded) {
    $env:GROK_CLI_CHAT_PROXY_BASE_URL = "http://127.0.0.1:8787/v1"
}
```

It is applied to the Grok variable and not to any of the others. This PBI generalises it.

**Acceptance criteria.**
- [ ] A single `Assert-EndpointAlive -Port <n> -Path '/v1/models'` helper performs a TCP check **and** an HTTP health probe. TCP alone is insufficient — a listener that returns 500 is not a working endpoint.
- [ ] No airlock code path writes a `*_BASE_URL` variable without a passing `Assert-EndpointAlive` in the same invocation.
- [ ] On failure, airlock writes nothing and emits a message naming the port, the check that failed, and the command to retry.
- [ ] The guard is applied uniformly to `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `OPENAI_API_BASE`, and the Grok variables — no exceptions.

**Verification.**
```powershell
ai-stop
$env:ANTHROPIC_BASE_URL   # MUST be empty — nothing is listening
```

**Dependencies.** AIR-1 (writes go through the ledger helper).

---

## AIR-3 — Teardown on stop

**Problem.** `Stop-AI.ps1` clears `.active-port.json` and `active-provider.json` but leaves every routing variable pointing at a port it just killed. The window between `ai-stop` and the next `ai-start` is one in which Claude Code, aider, and Copilot are all silently broken.

**Acceptance criteria.**
- [ ] `Stop-AI.ps1` calls `Restore-OwnedMutations` before it exits.
- [ ] Teardown is logged to the daily JSONL audit log with the same structure as other actions, listing each variable reversed.
- [ ] Teardown runs even if the backend process kill fails — a partial stop must not leave routing pointed at a dead port.
- [ ] A `-KeepRouting` flag exists for the deliberate case of stopping the backend while intending to restart it immediately.

**Verification.**
```powershell
ai-start; ai-stop
Get-ChildItem Env: | Where-Object { $_.Name -match 'ANTHROPIC|OPENAI|OLLAMA' }   # MUST be empty
```

**Dependencies.** AIR-1.

---

## AIR-4 — Session scope only

**Problem.** During the incident, `ANTHROPIC_BASE_URL` was found persisted at Windows **User** scope. A registry-persisted variable survives every settings edit, every terminal restart, and every application reinstall — it is invisible to every debugging technique a user will actually try. This is why the diagnosis took two hours.

Whether airlock or Headroom wrote that particular value was never established. Airlock must be provably not-guilty by construction.

**Acceptance criteria.**
- [ ] No airlock code path calls `[Environment]::SetEnvironmentVariable(..., 'User')` or `'Machine'` for any routing variable. Grep-enforced in CI.
- [ ] Routing variables are set in the current process only, and documented as per-shell.
- [ ] If persistent routing is genuinely wanted, it is a separate opt-in command (`ai-route-persist`) that prints an explicit warning describing this exact failure mode and how to reverse it.
- [ ] `ai-doctor` (AIR-10) reports any airlock-relevant variable found at User or Machine scope as a **warning**, with the removal command, regardless of who wrote it.

**Verification.** CI grep:
```
SetEnvironmentVariable\([^)]*,\s*'(User|Machine)'\)
```
must return no hits outside `ai-route-persist`.

---

## AIR-5 — Foreign-mutation detection

**Problem.** Airlock is not the only tool routing agent CLIs on this machine. When another tool has already claimed `ANTHROPIC_BASE_URL`, airlock overwriting it silently breaks that tool; airlock deferring silently confuses the user. Neither is acceptable.

**Design.** A known-tools table, extended as tools are encountered:

| Port | Tool | Signature |
|---|---|---|
| 8787 | Headroom | `~/.headroom/`, `headroom.EXE` on PATH |
| 12345 | Airlock | `~/.ai-platform/.active-port.json` |

**Acceptance criteria.**
- [ ] Before writing a routing variable, airlock reads the current value. If set and not written by airlock (per ledger), it attributes the value to a known tool where possible and reports it.
- [ ] Default behaviour is to **refuse and report**, not to overwrite. `-Force` overwrites, records the prior value in the ledger, and restores it on teardown.
- [ ] The report names the conflicting tool, its port, whether that port is currently alive, and the command to inspect it (e.g. `headroom doctor`).
- [ ] Detection is best-effort and never fatal — an unknown value is reported as "set by an unidentified tool" with the value shown.

**Verification.**
```powershell
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:8787"
ai-start   # MUST report a Headroom conflict and refuse to overwrite
```

**Dependencies.** AIR-1.

---

# EPIC B — Local backend correctness

*Goal: `ai-start` followed by `ai-code` produces a working, fast local coding session on the first try.*

---

## AIR-6 — Size model selection against VRAM

**Problem.** Observed startup:

```
  RAM: 87.7 GB free / 127.7 GB (68.7% free)
  GPU: 15 GB free / 16 GB
  Auto-selected model: qwen3-coder:30b (fits 87.7 GB available)
  Model 'qwen3-coder:30b' not found locally. Pulling it in the background...
```

`qwen3-coder:30b` is 18 GB against 15 GB of free VRAM. It cannot be GPU-resident, so Ollama offloads layers to CPU and throughput collapses. The startup line reports the GPU figure on the line above and then ignores it.

Meanwhile `qwen2.5-coder:7b` — measured at **91.55 tok/s generation, 267.57 tok/s prompt eval** on this hardware — was already pulled and available.

For an interactive agentic loop, a fast smaller model beats a slow larger one decisively. A 20-second iteration cycle is usable; a 3-minute cycle is not, regardless of output quality.

**Acceptance criteria.**
- [ ] Fit is computed as `modelSizeBytes * headroomFactor <= freeVramBytes`, with `headroomFactor` defaulting to 1.2 to account for KV cache and context growth. Factor is configurable in `models.json`.
- [ ] System RAM is evaluated as a secondary constraint only, for CPU-only fallback.
- [ ] **Already-pulled models are preferred over models requiring download** when both satisfy the VRAM constraint. Ties break toward the larger model.
- [ ] A model that fails the VRAM constraint is selected only if no candidate passes, and the banner then states explicitly: partial CPU offload, expect degraded throughput, here is the faster alternative.
- [ ] Selection rationale is logged with the numbers used: free VRAM, headroom factor, each candidate's size, each rejection reason.
- [ ] `-Model <name>` on `ai-start` overrides selection entirely, warns if the model fails the VRAM check, and proceeds.
- [ ] Multi-GPU: sum free VRAM across devices only when the runtime is configured for tensor parallelism; otherwise use the largest single device.

**Verification.** On this hardware with both models present, `ai-start` must select `qwen2.5-coder:7b` and must not initiate an 18 GB download.

---

## AIR-7 — Fix `ai-code`

**Problem.** Two independent defects in one function. Current deployed source:

```powershell
function global:ai-code {
    $file = "$env:USERPROFILE\.ai-platform\state\active-provider.json"
    if (-not (Test-Path $file)) { ...; return }
    $data = Get-Content $file -Raw | ConvertFrom-Json
    $modelArg = "openai/$($data.model)"
    aider --model $modelArg
}
```

**7a — the function accepts no parameters.** `ai-code -Model qwen2.5-coder:7b` silently discards the argument. PowerShell does not error; the flag simply vanishes. Observed: the session launched `qwen3-coder:30b` despite an explicit override.

**7b — it never passes `--openai-api-base` or a key.** aider resolves `openai/...` against the real OpenAI API. Observed:

```
litellm.AuthenticationError: OpenAIException - Incorrect API key provided: ollama.
You can find your API key at https://platform.openai.com/account/api-keys.
```

The environment was empty at the time — both `OPENAI_BASE_URL` and `OPENAI_API_KEY` unset — so there was no ambient fallback either.

**This contradicts the README**, which states `ai-code` "already launches it with `--openai-api-base` pointed at the platform."

**Acceptance criteria.**
- [ ] `ai-code` declares `[CmdletBinding()]` with a `-Model` parameter that is honoured.
- [ ] `-Model` is validated against `ollama list`; an absent model fails loudly with the available list and the `ollama pull` command.
- [ ] `ai-code` passes `--openai-api-base http://127.0.0.1:<port>/v1` and `--openai-api-key ollama` explicitly as arguments. It does not rely on ambient environment variables.
- [ ] `Assert-EndpointAlive` runs before launching aider; failure names the port and does not launch.
- [ ] Additional arguments pass through to aider unmodified (`@args`).
- [ ] Same treatment for any sibling launcher (`ai-hermes-start`, future wrappers) — explicit arguments, not ambient state.

**Interim workaround for the README until shipped:**
```powershell
aider --model openai/qwen2.5-coder:7b --openai-api-base http://127.0.0.1:12345/v1 --openai-api-key ollama
```

**Dependencies.** AIR-2 (`Assert-EndpointAlive`).

---

## AIR-8 — vLLM failure diagnostics

**Problem.** Observed:

```
Launching vLLM container (model: Qwen/Qwen2.5-Coder-7B-Instruct-AWQ)...
Waiting up to 120s for vLLM to load the model and become healthy...
ERROR: vLLM did not become healthy within 120s.
vLLM failed to start — falling back to Ollama.
```

120 seconds spent, one line of output, no exit code, no container logs, no failure class. `Get-BackendCapability.ps1` had already judged vLLM viable, so this tax is paid on every start with no path to fixing it.

**Acceptance criteria.**
- [ ] On timeout, capture and print the last 40 lines of `docker logs <container>`.
- [ ] Classify and name the common failure modes distinctly: image not present, model download in progress, insufficient VRAM, container exited with non-zero status, Docker daemon unreachable.
- [ ] Timeout is configurable; first run (which may include a multi-GB model download) gets a longer default than subsequent runs, keyed on whether the model is already in the HF cache.
- [ ] A vLLM failure is recorded in `provider-policy.json` with a timestamp and reason. Subsequent `ai-start` invocations skip vLLM and go straight to Ollama until `ai-start -RetryVllm` clears it.
- [ ] The skip is announced on startup so the user knows vLLM is being bypassed and why.

---

## AIR-9 — README/code parity

**Problem.** P7 violation, concrete instance: the README describes `ai-code` behaviour that the code does not implement. A user following the documentation hits an OpenAI authentication error and has no reason to suspect the docs.

**Acceptance criteria.**
- [ ] Every command the README documents has a smoke test that exercises the documented behaviour.
- [ ] The `ai-code` claim is corrected or the code is brought up to match (AIR-7 does the latter).
- [ ] CI runs the smoke suite; a documented-but-broken command fails the build.
- [ ] The README's Claude Code section carries the AIR-2/AIR-3/AIR-4 warnings: this redirect disables cloud Claude Code while active, the symptom is a misleading firewall message, and here is the reversal command.

---

# EPIC C — Observability & diagnosis

*Goal: the next incident of this class resolves in five minutes, not two hours.*

---

## AIR-10 — `ai-doctor`

**Problem.** The two hours were spent because nothing on the machine could answer "what is currently redirecting my agent CLIs, and is that target alive?" Headroom's own `headroom doctor` answered it in one command — once it occurred to anyone to run it. Airlock needs the equivalent, scoped wider than airlock's own variables.

**Design.** Model the output on `headroom doctor`: a table of checks, each pass/warn/fail, each failure carrying a remediation command.

**Acceptance criteria.**
- [ ] Reports every `ANTHROPIC_*`, `OPENAI_*`, `COPILOT_*`, `GROK_*`, and `OLLAMA_*` variable found at Process, User, and Machine scope — **with the scope labelled**, since scope determines how to remove it.
- [ ] For each variable pointing at a local port: reports whether anything is listening and whether it answers a health probe.
- [ ] Attributes each value to a known tool where possible (AIR-5 table), and marks airlock's own via the ledger.
- [ ] For every problem, prints the exact remediation command — including `[Environment]::SetEnvironmentVariable(..., $null, 'User')` for persistent-scope finds.
- [ ] Checks Claude Code's own config layers for `env` blocks: `~/.claude/settings.json`, `<project>/.claude/settings.json`, `<project>/.claude/settings.local.json`. All three were involved in the incident; `settings.local.json` was found last.
- [ ] Validates each of those files parses as JSON and names the file and line on failure.
- [ ] Exits non-zero when any check fails, so it is usable in scripts.
- [ ] Runs standalone without the platform started.

**Verification.** With `ANTHROPIC_BASE_URL` pointing at a dead port, `ai-doctor` must identify the variable, its scope, the dead port, the probable owning tool, and the removal command — in one invocation.

---

## AIR-11 — Startup preflight

**Problem.** Conflicts are currently discovered when something fails at use time, far from the cause.

**Acceptance criteria.**
- [ ] `ai-start` runs the `ai-doctor` conflict checks before starting anything.
- [ ] A foreign routing variable pointing at a **live** endpoint is reported and honoured (AIR-5).
- [ ] A foreign routing variable pointing at a **dead** endpoint is reported prominently with the removal command — this is the exact state that caused the incident, and it is silent today.
- [ ] Preflight adds no more than 2 seconds to startup.

**Dependencies.** AIR-5, AIR-10.

---

## AIR-12 — Visible model pull progress

**Problem.** Observed:

```
  Model 'qwen3-coder:30b' not found locally. Pulling it in the background...
  Pulling 'qwen3-coder:30b' in the background (job 7) — startup will continue without waiting
  ... check today's log at C:\Users\veere\.ai-platform\logs\2026-08-11.jsonl for progress
```

An 18 GB download with no percentage, rate, or ETA, and the user directed to grep a JSONL file. This reads as a hang.

**Acceptance criteria.**
- [ ] `ai-port` and `ai-health` report in-flight pull state: percent, bytes transferred, rate, ETA.
- [ ] `ai-pull-status` renders a live progress bar in the foreground; `ai-start -Wait` blocks with the same display.
- [ ] Completion emits a terminal line and, where available, a desktop notification.
- [ ] Progress output is human-readable prose; JSONL remains the machine-readable audit trail, not the user interface.
- [ ] Note: AIR-6 makes large background pulls rare, since already-present models are preferred. This PBI covers the remaining deliberate cases.

*(A `-Flavour` flag may add job-contextual humour to progress lines. Off by default — default output must stay parseable, and a stalled 18 GB download is not improved by a movie quote.)*

---

## AIR-13 — Attributed error messages

**Problem.** P6. "Connection refused — a firewall or proxy may be blocking it" is Claude Code's message, and airlock cannot change it. But airlock can ensure that *its* failures never present this way, and that `ai-doctor` is discoverable enough to be the first thing reached for.

**Acceptance criteria.**
- [ ] Every airlock error names the component, the endpoint attempted, and the remediation command.
- [ ] No airlock error surfaces a bare exception or a generic network message.
- [ ] Failures that leave the user unable to work print `Run 'ai-doctor' for a full diagnosis.` as the final line.
- [ ] `docs/` gains a troubleshooting page titled with the literal error strings users will paste into a search engine — including "Connection refused — a firewall or proxy may be blocking it" — that walks through base-URL diagnosis across all three scopes and all three Claude config files.

---

# EPIC D — Fallback contract

*Goal: state honestly what the local backend can and cannot do, so the feature is judged against a real promise.*

---

## AIR-14 — Model capability metadata

**Problem.** The reported symptom is that the local model "hallucinates and doesn't help at all with any repo, use plugins, or do tool calling." Three distinct causes are being conflated:

1. Wrong model at wrong speed — fixed by AIR-6.
2. Broken client wiring — fixed by AIR-7.
3. A genuine capability ceiling — not fixable by platform work.

A 7B coding model is materially weaker at multi-step tool calling, long-context repo reasoning, and instruction adherence than a frontier model. On an 858-file repository it will not behave like Sonnet. That is a model-tier fact, and the platform should encode it rather than let each user rediscover it as apparent breakage.

**Acceptance criteria.**
- [ ] `models.json` gains per-model fields: `toolCalling` (`none` / `partial` / `reliable`), `contextWindow`, `measuredTokensPerSec`, `suitableFor` (list of task classes).
- [ ] Values are populated from measurement on the target hardware, not from vendor claims. Baseline already measured: `qwen2.5-coder:7b` at 91.55 tok/s generation, 267.57 tok/s prompt eval.
- [ ] `ai-models` displays these fields.
- [ ] Selecting a model whose `toolCalling` is `none` or `partial` for an agentic harness produces a warning naming the limitation.

---

## AIR-15 — Harness compatibility matrix

**Problem.** "It connected" is not "it works." The README currently presents harness setup as configuration steps, without stating which harness/model combinations were actually tested to complete a real task.

**Acceptance criteria.**
- [ ] `docs/` gains a matrix: harness (Claude Code, aider, opencode, Hermes) × model tier × verdict, where verdict is based on completing a defined benchmark task, not on establishing a connection.
- [ ] The benchmark task is defined and reproducible — e.g. "add a passing unit test to an existing module in a repo of ≥500 files."
- [ ] Combinations that fail are listed as failing, with the failure mode named.
- [ ] The Claude Code section states plainly that Claude Code's system prompt and agentic loop assume a frontier-tier instruction-following model, and names the tier below which it is not viable.

---

## AIR-16 — Cloud-limit handoff policy

**Problem.** The actual goal — "continue my work even when Claude hits limits" — has no defined shape. Cross-harness session resume already exists (`docs/09-Cross-Harness-Session-Resume.md`, `.ai-context/SESSION_STATE.md`). What is missing is a policy for what moves local and what waits.

**Acceptance criteria.**
- [ ] A documented triage policy: which task classes are delegated to the local backend on a cloud limit (scoped single-file edits, test generation, boilerplate, code explanation, mechanical refactors) and which are deferred (architecture, multi-file agentic work, anything needing reliable tool calling on a large repo).
- [ ] `ai-handoff` writes the current session state in the format the local harness consumes, so the switch does not require re-explaining context.
- [ ] The reverse path is documented: returning to Claude Code with local work summarised rather than replayed.
- [ ] The policy is stated in terms of task class, not user discipline — a rule that depends on remembering it under pressure will not hold.

**Dependencies.** AIR-14, AIR-15.

---

## 5. Sequencing

**Phase 1 — Make it work** *(AIR-7, AIR-6)*
Two changes. `ai-code` currently cannot reach the local endpoint at all, and model selection actively picks the wrong model. Until both land, nothing else in the platform can be evaluated.

**Phase 2 — Make it safe** *(AIR-1, AIR-2, AIR-3, AIR-4)*
The governance foundation. AIR-1 first — AIR-2 and AIR-3 both depend on the ledger. This is the phase that guarantees airlock never becomes the next Headroom.

**Phase 3 — Make it diagnosable** *(AIR-10, AIR-5, AIR-11, AIR-13)*
`ai-doctor` first; it is the highest-leverage single item in the plan and is independently useful before the rest of the phase lands.

**Phase 4 — Make it honest** *(AIR-14, AIR-15, AIR-16, AIR-9, AIR-8, AIR-12)*
Documentation parity, capability metadata, and the polish items.

---

## 6. Definition of done for the plan as a whole

A user on a fresh machine can run:

```powershell
ai-start
ai-doctor
ai-code -Model qwen2.5-coder:7b
```

…and get a VRAM-resident model, a clean diagnostic table, and a working aider session that edits a real file. Then:

```powershell
ai-stop
claude
```

…and Claude Code works immediately, with no residual routing, no manual variable cleanup, and no interaction with whatever else on the machine touches `ANTHROPIC_BASE_URL`.

If any step in that sequence requires the user to know about environment-variable scopes, the plan is not done.

---

## 7. Out of scope

- **Fixing Headroom.** Its `persistent-docker` preset ships with `Supervisor: none`, so nothing restarts the proxy when Docker stops — that is a Headroom issue and belongs upstream. Airlock's job is to detect and report the resulting conflict, not to manage another tool's lifecycle.
- **The three remaining stale variables** on this machine (`OPENAI_API_BASE`, `GROK_MODEL_GROK_BUILD_BASE_URL`, `GROK_CLI_CHAT_PROXY_BASE_URL`, all pointing at 8787). Operational cleanup, not a code change. `ai-doctor` will surface them once AIR-10 lands.
- **ruflo's `.claude/agents/` footprint.** Separate concern; noted only because it contributed noise during diagnosis.

---

# Appendix A — Concrete artifact schemas

*Added 2026-08-12 after the Headroom root cause was confirmed. These remove implementation ambiguity from AIR-1, AIR-5, and AIR-10 — three PBIs that describe behaviour but not the on-disk contracts they depend on. A reviewer should be able to implement against these without a design conversation.*

## A.1 Mutation ledger (AIR-1)

`~/.ai-platform/state/mutation-ledger.json`

```json
{
  "schema": "airlock.mutation-ledger/v1",
  "entries": [
    {
      "kind": "env",
      "name": "OPENAI_BASE_URL",
      "value": "http://127.0.0.1:12345/v1",
      "previousValue": null,
      "scope": "Process",
      "purpose": "aider -> local Ollama",
      "setBy": "Start-AI.ps1",
      "pid": 12345,
      "port": 12345,
      "setAt": "2026-08-12T14:22:03.1234567Z"
    },
    {
      "kind": "file",
      "path": "C:/Users/veere/.codex/config.toml",
      "selector": "model_providers.airlock",
      "previousValue": null,
      "purpose": "Codex -> local Ollama",
      "setBy": "ai-codex-on",
      "setAt": "2026-08-12T14:25:11.0000000Z"
    }
  ]
}
```

**Contract.**

- `previousValue: null` means the key did not exist. Teardown **removes** it.
- `previousValue: "<string>"` means a prior value existed. Teardown **restores** that exact string. This is what prevents airlock from clobbering a Headroom-set value on `ai-stop` — the case P1 exists to prevent.
- Writes are atomic: serialise to `mutation-ledger.json.tmp`, then move over the target. A partial write must never destroy the ledger, since a lost ledger means unreversible mutations.
- A corrupt or absent ledger is rebuilt empty with a warning. Airlock must still start.
- `kind: "file"` entries carry a `selector` naming the specific key touched, so teardown never rewrites a whole third-party config file.

## A.2 Known-owner registry (AIR-5, AIR-10)

`config/known-endpoint-owners.json` — ships with airlock, user-extensible.

This is the file that converts *"unknown variable pointing at a dead port"* into *"Headroom — run `headroom doctor`."* It is the single highest-value artifact in the plan, because it also covers failures airlock did not cause.

```json
{
  "schema": "airlock.endpoint-owners/v1",
  "owners": [
    {
      "tool": "Headroom",
      "detect": { "binaries": ["headroom", "headroom.exe"],
                  "paths": ["~/.local/bin/headroom.exe"] },
      "defaultPorts": [8787],
      "variables": ["ANTHROPIC_BASE_URL", "OPENAI_API_BASE",
                    "COPILOT_PROVIDER_BASE_URL",
                    "GROK_CLI_CHAT_PROXY_BASE_URL",
                    "GROK_MODEL_GROK_BUILD_BASE_URL"],
      "diagnose": "headroom doctor",
      "start":    "headroom proxy",
      "remove":   "headroom unwrap claude",
      "note": "Docker-hosted. Check `headroom install status --profile default` — a persistent-docker preset with Supervisor:none does not survive a Docker restart."
    },
    {
      "tool": "Airlock",
      "defaultPorts": [12345],
      "variables": ["ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "OPENAI_API_KEY", "OLLAMA_HOST"],
      "diagnose": "ai-doctor",
      "start":    "ai-start",
      "remove":   "ai-stop"
    }
  ]
}
```

**Contract.**

- Matching is by variable name **and** port. A variable airlock owns per the ledger is never attributed elsewhere.
- Detection is best-effort. An unmatched variable reports `unknown owner` with the scopes it was found in — never a guess presented as fact.
- Registry entries are advisory text only. Airlock **never executes** another tool's `start` or `remove` command; it prints them. Managing a third party's lifecycle is explicitly out of scope.

## A.3 `ai-doctor` reference output (AIR-10)

The target shape. Every line here maps to something that actually cost time during the incident.

```
Airlock Doctor · LLM endpoint routing

  ANTHROPIC_BASE_URL   http://127.0.0.1:8787    DEAD   [User scope]   HIGH
      Owner     : Headroom  (binary at ~/.local/bin/headroom.exe)
      Diagnose  : headroom doctor
      Start     : headroom proxy
      Remove    : headroom unwrap claude
      Persisted at User scope — survives shell and app restarts. Clear with:
        [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $null, 'User')

  OPENAI_BASE_URL      http://127.0.0.1:12345/v1  LIVE   [Process]
      Owner     : airlock (Start-AI.ps1, 2026-08-12T14:22:03Z)

  Also declared in file:
      .claude/settings.local.json -> env.ANTHROPIC_BASE_URL
      Clearing the environment variable alone will NOT fix this.

  Docker daemon: not running
      Affects vLLM backend and any Docker-hosted proxy (incl. Headroom).

  Running clients hold the environment from their launch time:
      claude (PID 41288, started 09:14)   ← relaunch after fixing

  2 issue(s) found. Exit code 1.
```

**Required behaviours, each traceable to an hour lost during the incident.**

| Behaviour | What it would have prevented |
|---|---|
| Report the **scope** of every hit | User-scope persistence defeated ~6 attempted fixes |
| Report **duplicate declarations** in client config files | The `settings.local.json` duplicate meant clearing the env var appeared to do nothing |
| Name the **likely owner** with its diagnostic command | `headroom doctor` answered in 5 seconds once found; nothing pointed there |
| Warn about **stale client processes** | `claude -p` succeeded while the TUI still failed, purely because the TUI predated the fix |
| Report **Docker daemon state** | The root cause was a stopped container with no supervisor |
| Print an explicit **all-clear** when healthy | Silence is indistinguishable from a broken check |
| **Exit non-zero** on any dead endpoint | Makes it usable in `ai-start` preflight and CI |

---

# Appendix B — Traceability and CI regression suite

*Principles are only binding if something fails when they are violated. Each test below encodes a failure that actually occurred.*

## B.1 Principle → PBI → test

| Principle | PBIs | Tests |
|---|---|---|
| P1 Never mutate what you do not own | AIR-1, AIR-3, AIR-5 | R-3, R-4, R-5 |
| P2 Never route to an unverified endpoint | AIR-2, AIR-11 | R-1, R-2 |
| P3 Session scope by default | AIR-4 | R-6, R-7 |
| P4 Every mutation reversible by one command | AIR-3, AIR-9 | R-5, R-8 |
| P5 Fit against the binding constraint | AIR-6 | R-9, R-10 |
| P6 Failures name themselves | AIR-10, AIR-13 | R-11, R-12 |
| P7 Documentation claims are tested | AIR-7, AIR-9, AIR-15 | R-13, R-14 |

## B.2 Regression suite

| # | Test | Assertion |
|---|---|---|
| R-1 | Write a `*_BASE_URL` with nothing listening | Fails closed; variable unset; message names the port |
| R-2 | Listener returns HTTP 500 on `/v1/models` | Treated as dead — TCP-open alone must not pass |
| R-3 | Foreign value pre-set, then `ai-stop` | Foreign value **preserved**, not deleted |
| R-4 | Foreign value pre-set, then `ai-claude-on` | Aborts; names current value and likely owner; `-Force` required |
| R-5 | `ai-start` → `ai-stop` → `ai-stop` | All airlock vars cleared; second run a clean no-op |
| R-6 | After any airlock set, read `User` and `Machine` scope | Both `$null` |
| R-7 | Grep repo for `$env:*_BASE_URL =` outside the ledger helper | Zero hits |
| R-8 | `ai-memory-on` → `ai-memory-off` | `directEndpoint` restored exactly; no residual key |
| R-9 | 16 GB VRAM; 30B and 7B both present | Selection returns the **7B** |
| R-10 | Target model absent, smaller model present | Prefers the **present** model; no background pull |
| R-11 | Dead endpoint present → `ai-doctor` | Exit code 1; owner, scope, and fix command all printed |
| R-12 | Var set in env **and** in `.claude/settings.local.json` | Both locations reported |
| R-13 | Construct `ai-code -Model X` argument list | Contains `X` **and** `--openai-api-base` on a loopback address |
| R-14 | Every README command block | Executes successfully, or is marked `<!-- notest -->` with a reason |

R-7 and R-14 are the durability tests: R-7 stops the ledger from being bypassed as the codebase grows, R-14 stops README drift of exactly the kind that produced the false `--openai-api-base` claim.

## B.3 Acceptance walkthrough

The epic is done when this passes on a clean machine, with **no step requiring knowledge of environment-variable scopes**:

```powershell
ai-doctor                          # all-clear, exit 0
ai-start                           # VRAM-resident, already-present model
ai-health                          # backend healthy, endpoint live
ai-code -Model qwen2.5-coder:7b    # honours flag, reaches local endpoint
#   → apply one real single-file edit and confirm it lands
ai-stop                            # every mutation reversed
ai-doctor                          # all-clear, exit 0
```

Then the adversarial pass — the incident, reproduced:

```powershell
[Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL','http://127.0.0.1:8787','User')
ai-doctor
#   MUST: name Headroom, report User scope as HIGH, print the clear command,
#         warn about running clients, and exit 1.
ai-stop
#   MUST NOT delete it — airlock does not own it (P1).
```

That second block is the real test of this plan. Airlock did not cause the outage; the standard is that it would have **ended** it in seconds.
