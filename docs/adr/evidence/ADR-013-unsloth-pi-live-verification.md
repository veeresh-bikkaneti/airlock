# ADR-013: Unsloth Qwen3.8-27B (`llamacpp-qwen38-ud-q3-k-xl`) — Pi harness live verification

## Verdict

**PASS — 3/3 real trials, real structured tool events.** `Invoke-AirlockPiCapabilityContract`
was run for real against a real `llama-server` instance, the real `hermes-container-hermes-agent`
Docker image, and the real Pi CLI (`@earendil-works/pi-coding-agent`) inside that container. All
three trials produced a genuine `read` tool call on `seed.md`, a genuine `write` tool call on
`output.md` with the exact marker content, and a final `DONE` reply, then exited 0. Raw per-trial
stdout/stderr/output.md are preserved (see "Artifacts" below); the pass is backed by inspecting
those files directly, not just the harness's own boolean summary.

`candidateOnly` is flipped to `false` for `llamacpp-qwen38-ud-q3-k-xl` in
`config/agent-profiles.json` on this basis.

## A real bug was found and fixed along the way (AGENT-PI-01)

The first live run (before any fix) did **not** pass — it hung well past what a 3-word tool-call
probe should take. Investigating the running container's logs
(`docker logs <id>`) showed the model receiving the fixed §7.2 instruction one **word** at a
time as separate conversation turns:

```
"role":"user","content":[{"type":"text","text":"Read"
"role":"user","content":[{"type":"text","text":"Read"
"role":"user","content":[{"type":"text","text":"Read"
"role":"user","content":[{"type":"text","text":"seed.md."
"role":"user","content":[{"type":"text","text":"seed.md."
"role":"user","content":[{"type":"text","text":"seed.md."
"role":"user","content":[{"type":"text","text":"Create"
...
```

Root cause: `Invoke-PiWorkspaceTrial` called `Start-Process -FilePath "docker" -ArgumentList
$runArgs` with `$runArgs` as a `string[]`. `Start-Process -ArgumentList` joins array elements
into one command line with a plain space and does **not** quote elements that themselves contain
spaces. `Get-PiContainerRunArgs`'s last element is the entire multi-sentence instruction
(`"Read seed.md. Create output.md containing exactly the value after MARKER=. Do not access files
outside this workspace. Reply exactly DONE."`) — so each of its words became a separate `docker
run` argv entry, and pi's `pi [options] [--] [@files...] [messages...]` positional syntax (`--help`
confirms `messages...` is plural) treated each word as its own sequential turn instead of one
instruction. Reproduced directly, isolated from Pi/llama-server entirely:

```powershell
$runArgs = @("run","--rm","hermes-container-hermes-agent","printf","%s\n","Read seed.md. Create output.md.")
Start-Process -FilePath docker -ArgumentList $runArgs -NoNewWindow -Wait -RedirectStandardOutput out.log
# out.log:
#   Read
#   seed.md.
#   Create
#   output.md.
```

**Fix** (`scripts/Invoke-PiCapabilityContract.ps1`): added `ConvertTo-AirlockCmdLineArg`, a Win32
`CommandLineToArgvW`-style per-argument quoter, applied to every element of `$runArgs` before
joining into a single pre-quoted command-line string passed to `Start-Process -ArgumentList`
(kept as file-redirected stdout/stderr, same as before — no pipe-based `StreamReader` capture,
which would risk a deadlock now that `--mode json` stdout runs past 70KB; an earlier attempt at
this fix used `ProcessStartInfo` + async event handlers and crashed with `PSInvalidOperationException:
There is no Runspace available to run scripts in this thread` because .NET stream-data-received
events fire on a thread pool thread with no PowerShell runspace — reverted in favor of the
simpler file-redirection approach, which was already deadlock-safe). Verified the fix in isolation
the same way the bug was reproduced:

```powershell
$runArgs = Get-PiContainerRunArgs ... -Instruction "Read seed.md. Create output.md."
docker run --rm --entrypoint printf hermes-container-hermes-agent "ARG:[%s]\n" $runArgs[-1]
# ARG:[Read seed.md. Create output.md.]   <- one argument, not four
```

A regression test was added to `scripts/Test-PiCapabilityContract.ps1` for
`ConvertTo-AirlockCmdLineArg` (multi-word instruction stays one arg; embedded quotes are escaped;
plain single-word args pass through unquoted). Full unit suite (`pwsh -File
scripts/Test-PiCapabilityContract.ps1`) passes, 18/18 checks, after the fix.

This is the same category of bug as the four fixes already committed in 535a3bb (entrypoint
dropping CMD args, CRLF shebang, nonexistent `--prompt` flag, out-of-workspace regex false
positive) — genuine harness/plumbing wiring, not a model capability issue, model held constant
throughout.

## Environment

- Hardware: RTX 5000 Ada Generation Laptop GPU, 16376 MiB total VRAM. 13998 MiB used / 2051 MiB
  free with the model loaded (measured via `nvidia-smi` during the passing run).
- `llama-server` `0.3.0-dev (build 10689, commit 57291f264)` (winget `ggml.llamacpp`) — same build
  the prior opencode-harness attempt (`docs/adr/evidence` on `feature/adr-013-unsloth-verification`,
  commit `9768edf`, not merged into this branch) used.
- Model: `unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL`, already present on disk at
  `~/.ai-platform/models/Qwen3.8-27B-UD-Q3_K_XL.gguf` (13,146,393,504 bytes, independently
  verified via `stat` this session — not re-downloaded).
- `/props` template verification: `Reachable: True`, `TemplateVerdict: Pass`,
  `TemplateIdentity: sha256:12827f24b742ea4e80cdc12dbcf9622227056b9f797252a3149263d4f9aaadce`
  (same template hash as the prior opencode attempt — same model/build).
- Docker: Desktop, server `29.7.2`. Image `hermes-container-hermes-agent` built fresh this
  session from `hermes-container/Dockerfile` (`docker build -t hermes-container-hermes-agent
  hermes-container/`) — all layers either cached or rebuilt clean, no errors.
- `runtimeArgs` used exactly as committed in `config/agent-profiles.json`:
  `["--jinja", "--flash-attn", "on", "--n-gpu-layers", "all", "--reasoning-effort", "low"]`,
  `initialContext: 8192`. `llama-server` started via the real `Start-LlamaCppRuntime` adapter
  (`scripts/runtime-adapters/llamacpp.ps1`), not a hand-rolled invocation; health check passed
  within the timeout, port auto-selected (`51865` this run).

## Method

A driver script (kept outside the repo, in the session scratchpad — `Invoke-WorkspaceContract.ps1`
and `Invoke-PiCapabilityContract.ps1` needed no changes to their *contract logic*, only the one
process-invocation bug fixed above) dot-sources `scripts/Invoke-PiCapabilityContract.ps1`
unmodified-except-for-the-bugfix and calls the real `Invoke-AirlockWorkspaceContract` /
`Invoke-PiWorkspaceTrial` functions exactly as `Start-AgentSession.ps1` does for the `pi-worker`
harness (`Invoke-AirlockPiCapabilityContract -ModelRef $selectedProfile.modelRef -EndpointUrl
$endpointUrl -WorkspaceRoot $WorkspaceRoot`, `$endpointUrl = "$baseUrl/v1"` from the real
`Start-LlamaCppRuntime` result) — same wiring, zero drift from the real contract path. The
`-Invoke` scriptblock passed to `Invoke-AirlockWorkspaceContract` was wrapped only to copy
`.stdout.log`/`.stderr.log`/`output.md`/`seed.md` out of each disposable workspace before the
shared `Invoke-AirlockWorkspaceTrial` `finally` block deletes it, so the raw artifacts below
survive for inspection.

Exact commands run:

```powershell
docker build -t hermes-container-hermes-agent hermes-container/

# Start-LlamaCppRuntime -ModelPath ~/.ai-platform/models/Qwen3.8-27B-UD-Q3_K_XL.gguf `
#   -Context 8192 -RuntimeArgs @("--jinja","--flash-attn","on","--n-gpu-layers","all","--reasoning-effort","low") `
#   -HealthTimeoutSec 300
# -> Started=True, BaseUrl=http://127.0.0.1:51865, Port=51865

Invoke-AirlockWorkspaceContract -WorkspaceRoot $wsRoot -TrialCount 3 -Invoke {
    param($WorkspacePath, $Marker)
    Invoke-PiWorkspaceTrial -WorkspacePath $WorkspacePath -Marker $Marker `
        -ModelRef "unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL" -EndpointUrl "http://127.0.0.1:51865/v1" `
        -ImageName "hermes-container-hermes-agent"
}
```

## Results (exact, from `contract-result.json`)

```json
{
  "Passed": true,
  "Reason": "All 3 trials passed.",
  "Trials": [
    { "Passed": true, "Reason": "Exact marker echoed; no boundary or tool-event violations.",
      "LatencyMs": 20743.4065, "SanitizedInfo": "exitCode=0",
      "UsedValidStructuredToolEvents": true, "OutOfWorkspaceRequestDetected": false },
    { "Passed": true, "Reason": "Exact marker echoed; no boundary or tool-event violations.",
      "LatencyMs": 27309.7347, "SanitizedInfo": "exitCode=0",
      "UsedValidStructuredToolEvents": true, "OutOfWorkspaceRequestDetected": false },
    { "Passed": true, "Reason": "Exact marker echoed; no boundary or tool-event violations.",
      "LatencyMs": 22492.5514, "SanitizedInfo": "exitCode=0",
      "UsedValidStructuredToolEvents": true, "OutOfWorkspaceRequestDetected": false }
  ],
  "TransportReturnedValidToolEvents": true
}
```

Per-trial `output.md` content, byte-compared against the marker written into that trial's
`seed.md`:

| Trial | `seed.md` marker | `output.md` content | Match |
|---|---|---|---|
| 1 | `b829a57178327972703c242afed73cdf` | `b829a57178327972703c242afed73cdf` | exact |
| 2 | `c0659d52aead30c189aea60240bef316` | `c0659d52aead30c189aea60240bef316` | exact |
| 3 | `ab12260d53b228b4d59d222141e72c25` | `ab12260d53b228b4d59d222141e72c25` | exact |

Every trial's `.stderr.log` contains exactly one line, non-fatal:
```
Warning: Model "unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL" not found for provider "ollama-local". Using custom model id.
```
Pi's local `models.json` catalog (patched into the container by `entrypoint.sh`) doesn't list this
HF-style model ref under `ollama-local`'s `models` array — `entrypoint.sh` only rewrites that
provider's `baseUrl`, not its `models` list. Pi falls back to treating the `--model` value as a
"custom model id" and proceeds correctly against the real endpoint regardless — confirmed by every
trial's `exitCode=0`, correct tool calls, and exact marker match. Noted as a real (harmless)
mismatch, not silently ignored — see "Follow-up" below.

## Not gaming the pass: what was checked beyond the harness's own boolean

Per this repo's standing discipline (the xLAM near-miss: proxy/transport passed 3/3 while the real
capability contract failed 3/3, and only reading the raw artifacts caught it), the harness's
`Passed: true` was not taken at face value. Read directly for all three trials:

- **`output.md` byte content** (table above) — independently re-compared here against each
  trial's own `seed.md`, not just trusting `Resolve-AirlockWorkspaceTrialVerdict`'s internal
  comparison.
- **Raw `stdout.log` event-type histogram** (trial 1, representative of all three):
  `toolcall_start`/`toolcall_delta`/`toolcall_end` (×2 each) and
  `tool_execution_start`/`tool_execution_end` (×2) — i.e. exactly two real tool invocations, not a
  regex match on "tool" appearing inside prose text.
- **Tool call arguments, verbatim from the event stream**:
  `{"name":"read","arguments":{"path":"seed.md"}}` then
  `{"name":"write","arguments":{"path":"output.md","content":"<exact marker>"}}` — the model
  read the real seed file and wrote the real marker value, not a hallucinated/hardcoded value.
- **Distinct `toolCallId` count**: exactly 2 per trial (one `read`, one `write`) — not a
  tool-result retry loop dressed up as a pass (the same failure shape
  `Resolve-AirlockPiTrialObservations`'s `ToolResultLoopDetected` regex targets, checked
  independently here rather than trusting only that regex).
  Trial 1: `FCPyMRTzIZ25WFdmCHku6LQszOQ6I3xa`, `myfPRGfMILfOFErgcwiNozzQVTpIzdQx`.
  Trial 2: `gdKPyqiZXJmFZ0gB9g4neBLqZXAgGFa5`, `y2YQpVUcXhHHwsBjjCitCLc4Wei4DTbz`.
  Trial 3: `BTbxgO0Q95BbTsMKI4KJqF5oF3ZTOCKu`, `PNFtHzhEThdXESghIZQsJgBvaXSdsXCy`.
- **Clean session termination**: every trial ends with `{"type":"text","text":"DONE"}` followed by
  `turn_end`, `agent_end`, `agent_settled` — not a truncated/killed process (`exitCode=0` in all
  three, corroborated independently from `$LASTEXITCODE`/`$proc.ExitCode`, not only the harness's
  `ProcessSucceeded` flag).
- **No out-of-workspace path requests** — `OutOfWorkspaceRequestDetected: false` in all three,
  and manually grepped each `stdout.log` for absolute POSIX paths outside `/workspace`: none found.

This rules out the xLAM failure shape (transport/proxy-layer pass masking a real capability fail):
here the transport, the template, the tool-call wiring, *and* the actual read/write file operation
all independently check out from raw artifacts, not just the harness's aggregate boolean.

## Follow-up (not blocking, disclosed rather than worked around silently)

`hermes-container/config/models.json`'s `ollama-local` provider entry doesn't include this
profile's `modelRef` (`unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL`) in its `models` array —
`entrypoint.sh` only patches `baseUrl` at container start, not the `models` list. Pi tolerates
this today (falls back to a "custom model id" with a stderr warning, no functional impact — see
results above), but a stricter provider validator in a future Pi release could turn this into a
hard failure. Not fixed here: `hermes-container/config/models.json` is a shared file backing every
profile's session (not just this candidate's contract), so a scope-driven edit belongs to whichever
task owns the container's model catalog, not this live-verification pass.

## Artifacts

Raw per-trial `.stdout.log` (event stream), `.stderr.log`, `seed.md`, `output.md`, and
`observations.json` for all three trials, plus `contract-result.json`, were preserved in the
session scratchpad during this run (not committed to the repo — matches this repo's existing
practice of keeping raw trial logs out of version control; the byte-for-byte content relevant to
the verdict is quoted verbatim above).
