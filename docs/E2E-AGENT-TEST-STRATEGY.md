# E2E agent test strategy

A certificate is a measurement on THIS machine. SKIP is a result. Do not claim dsh, a Grok hard-limit capture, or a live Pi 3/3 unless that command was actually run and its output is quoted.

You are an external agent (for example Manus, at manus.im) on a Windows PC with this repo checked out. Run the commands below and write one human-readable report. Do not merge. Do not push. Do not open a pull request. Do not edit product code. The only file you may create is the report:

`docs/e2e-reports/<yyyy-MM-dd>-<hostname>.md`

That glob is gitignored. Creating the `docs/e2e-reports` directory is allowed. Do not `git add` the report.

The report file starts with the honesty rule above, then the Record first block (command output quoted, not paraphrased), then the table. Fill every row. A row you did not run is `NOT RUN`, not a blank and not a pass.

## Record first

From the repo root, in PowerShell 7, run these and paste the full output at the top of the report. If a command is missing, paste the error. Do not invent GPU, RAM, or a commit SHA.

```powershell
git rev-parse HEAD
Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber | Format-List
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { nvidia-smi } else { Write-Output 'nvidia-smi: NOT PRESENT' }
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Output ("RAM total bytes: {0}" -f $cs.TotalPhysicalMemory)
Write-Output ("RAM free KB (Win32_OperatingSystem.FreePhysicalMemory): {0}" -f $os.FreePhysicalMemory)
```

## Phase A — unit, no GPU

Working directory: repo root. Run each script in this order, one command each. Record the last 5 lines and the exit code (`$LASTEXITCODE`). The expected ending for a PowerShell suite is the line that contains `passed`, or that script's own success line.

Stop the phase on the first FAIL (non-zero exit, or a line that says `FAIL`). Do not run the rest. Mark every later script, including pytest, `NOT RUN`.

A SKIP is only for the pytest row when `python` is not on PATH. Do not skip a PowerShell script because it looks unrelated.

```powershell
pwsh -NoProfile -File scripts/Test-AdapterContractHelpers.ps1
pwsh -NoProfile -File scripts/Test-AgentCapabilityRegistry.ps1
pwsh -NoProfile -File scripts/Test-AgentJobHelpers.ps1
pwsh -NoProfile -File scripts/Test-AgentOpenClawHelpers.ps1
pwsh -NoProfile -File scripts/Test-AgentOperatingContract.ps1
pwsh -NoProfile -File scripts/Test-AgentProfileHelpers.ps1
pwsh -NoProfile -File scripts/Test-AgentStart.ps1
pwsh -NoProfile -File scripts/Test-AgentStateHelpers.ps1
pwsh -NoProfile -File scripts/Test-BackendCapability.ps1
pwsh -NoProfile -File scripts/Test-ClaudeToggle.ps1
pwsh -NoProfile -File scripts/Test-Doctor.ps1
pwsh -NoProfile -File scripts/Test-FailLedger.ps1
pwsh -NoProfile -File scripts/Test-HarnessConfigTransaction.ps1
pwsh -NoProfile -File scripts/Test-HFSizeFit.ps1
pwsh -NoProfile -File scripts/Test-InstallDrift.ps1
pwsh -NoProfile -File scripts/Test-InvokeOpenClawJobDispatch.ps1
pwsh -NoProfile -File scripts/Test-LlamaCppAdapter.ps1
pwsh -NoProfile -File scripts/Test-LMStudioAdapter.ps1
pwsh -NoProfile -File scripts/Test-ModelSelection.ps1
pwsh -NoProfile -File scripts/Test-OllamaAdapter.ps1
pwsh -NoProfile -File scripts/Test-OpenCodeCapabilityContract.ps1
pwsh -NoProfile -File scripts/Test-PerfProbe.ps1
pwsh -NoProfile -File scripts/Test-PiCapabilityContract.ps1
pwsh -NoProfile -File scripts/Test-PullProgress.ps1
pwsh -NoProfile -File scripts/Test-RepairLoopCapabilityContract.ps1
pwsh -NoProfile -File scripts/Test-SessionResume.ps1
pwsh -NoProfile -File scripts/Test-StartAgentSession.ps1
pwsh -NoProfile -File scripts/Test-StartAgentWorkerJob.ps1
pwsh -NoProfile -File scripts/Test-StoragePreflight.ps1
pwsh -NoProfile -File scripts/Test-TaskRoute.ps1
pwsh -NoProfile -File scripts/Test-ToolProxyLifecycle.ps1
pwsh -NoProfile -File scripts/Test-Uninstall.ps1
pwsh -NoProfile -File scripts/Test-WorkspaceContract.ps1
```

If `Get-Command python` succeeds, also run:

```powershell
python -m pytest memory-service/tests tool-proxy/tests -q
```

If `python` is missing, that row is SKIP with the reason `python not on PATH`. Do not substitute `py` or `python3` and then call it the same command.

## Phase B — resume fixtures

These cases live in `scripts/Test-SessionResume.ps1` (already listed in Phase A). Do not run it early to skip a failure above. If Phase A stopped before that script, every row here is `NOT RUN`.

Quote the matching `PASS:` line from that run. The script's pass sentence is:

`All session resume checks passed`

Named cases (the report row is FAIL if that line is missing or says FAIL):

| Case | Pass line to quote |
|---|---|
| Parser reads the canonical block | `PASS: parser reads both turns, newest first` |
| Packet keeps only the latest turn | `PASS: packet does not contain an older turn when two turns were stored` |
| Path allow/deny | `PASS: SESSION_STATE.md is denied` and `PASS: RESUME_PACKET.md is the only allowed .ai-context file` |
| Normal source file | `PASS: a normal source file is allowed` |
| Atomic write plus preserved route | `PASS: atomic write preserves the Task route section unchanged` and `PASS: atomic write leaves no temp file` |
| At most 10 turns and 12 changed files | `PASS: summary stores at most 10 turns` and `PASS: packet lists at most 12 changed files` |
| Worker task unchanged without session text | `PASS: worker task is unchanged when session text is absent` |
| Worker task prepends the packet | `PASS: worker task is prepended with the packet when session text exists` |
| Pi instruction unchanged without a packet | `PASS: Get-PiContainerRunArgs without -ResumePacket ends with the original instruction` |
| Both skill files under a temp home | `PASS: both skill files land under the temp home` |
| Grok writer, git facts, no transcript line | `PASS: grok-session-end records the HEAD subject` and `PASS: omitted -TurnsJson stores the git-state-only summary line` |
| Suite | `All session resume checks passed` |

This phase does not start Grok, Docker, or a GPU. A green Phase B is not a live Pi 3/3 and not a Grok hard-limit capture.

## Phase C — live, Windows + GPU only

If Record first shows `nvidia-smi: NOT PRESENT`, or `nvidia-smi` exits non-zero, or it reports no GPU, the whole phase is SKIP with that reason. SKIP is not FAIL. Do not run the coding door. Do not claim a live Pi 3/3.

If there is an NVIDIA GPU, from the repo root:

```powershell
pwsh -NoProfile -File .\scripts\Start-AgentSession.ps1 -Harness pi-worker -DownloadConfirmed
```

That is the `ai-agent-start -Harness pi-worker` door. `ai-agent-start` in `scripts/profile-helpers.ps1` does not declare `-Harness`; it always calls this script with `pi-worker`. Do not pass `-Profile` unless you mean a specific catalogue entry. No `-Profile` sizes this PC. `-WhatIf` is not a certificate.

This can download a multi-gigabyte GGUF and needs Docker. If you will not spend that disk or time, mark the phase SKIP with that reason. Do not mark it PASS.

What a PASS looks like, on THIS run only:

- Exit code 0.
- The console line that starts with `SUCCESS:`.
- `%USERPROFILE%\.ai-platform\state\active-agent.json` is published only after the contract passes. Quote `harness` (must be `pi-worker`), `model`, `provenAt`, `expiresAt`, and `capabilityEvidenceKey`.
- Record `provenAt` before the command if the file already exists. A pre-existing file is not a PASS. A failed run must leave a prior file untouched; that run is still FAIL.
- Quote the contract output that shows the Pi trials. Do not write "3/3" unless this run's output says the contract passed.

A Docker-missing or contract-failed message is FAIL. Quote it. Do not soften it into a pass.

## Phase D — memory

`ai-memory-start` is opt-in. Do not start it unless you are measuring memory on purpose. The default listen port is 12346.

```powershell
$open = $false
try {
    $client = [System.Net.Sockets.TcpClient]::new()
    $client.Connect('127.0.0.1', 12346)
    $open = $client.Connected
    $client.Close()
} catch { $open = $false }
if ($open) { 'memory port 12346 open' } else { 'memory port 12346 closed' }
```

If the port is closed, coding is **no recall**. That is not a failed coding door. Do not flip Phase C to FAIL because memory is down. The Phase D row is SKIP with reason `port closed — no recall` when you did not opt in.

If you did opt in (`ai-memory-start`) and the port is open, quote `ai-memory-status` or the health response and mark PASS. If you opted in and it failed to start, that row is FAIL for memory only. Coding is still "no recall" or "recall", not a different door.

memory-service is the only RAG path. Do not describe a second vector database.

## Report template

Copy this table into the report and fill it. `Not claimed` stays filled even on a green run.

| Capability | Command | PASS/FAIL/SKIP/NOT RUN | Evidence (quote) | Not claimed |
|---|---|---|---|---|
| Record: HEAD | `git rev-parse HEAD` |  |  | another PC's certificate |
| Record: OS | `Get-CimInstance Win32_OperatingSystem` |  |  | |
| Record: GPU | `nvidia-smi` |  |  | live Pi 3/3, unless Phase C quoted it |
| Record: RAM | Win32 total / free |  |  | |
| Test-AdapterContractHelpers | `pwsh -NoProfile -File scripts/Test-AdapterContractHelpers.ps1` |  |  | |
| Test-AgentCapabilityRegistry | `pwsh -NoProfile -File scripts/Test-AgentCapabilityRegistry.ps1` |  |  | |
| Test-AgentJobHelpers | `pwsh -NoProfile -File scripts/Test-AgentJobHelpers.ps1` |  |  | |
| Test-AgentOpenClawHelpers | `pwsh -NoProfile -File scripts/Test-AgentOpenClawHelpers.ps1` |  |  | |
| Test-AgentOperatingContract | `pwsh -NoProfile -File scripts/Test-AgentOperatingContract.ps1` |  |  | |
| Test-AgentProfileHelpers | `pwsh -NoProfile -File scripts/Test-AgentProfileHelpers.ps1` |  |  | |
| Test-AgentStart | `pwsh -NoProfile -File scripts/Test-AgentStart.ps1` |  |  | live Pi 3/3 |
| Test-AgentStateHelpers | `pwsh -NoProfile -File scripts/Test-AgentStateHelpers.ps1` |  |  | |
| Test-BackendCapability | `pwsh -NoProfile -File scripts/Test-BackendCapability.ps1` |  |  | |
| Test-ClaudeToggle | `pwsh -NoProfile -File scripts/Test-ClaudeToggle.ps1` |  |  | |
| Test-Doctor | `pwsh -NoProfile -File scripts/Test-Doctor.ps1` |  |  | |
| Test-FailLedger | `pwsh -NoProfile -File scripts/Test-FailLedger.ps1` |  |  | |
| Test-HarnessConfigTransaction | `pwsh -NoProfile -File scripts/Test-HarnessConfigTransaction.ps1` |  |  | |
| Test-HFSizeFit | `pwsh -NoProfile -File scripts/Test-HFSizeFit.ps1` |  |  | |
| Test-InstallDrift | `pwsh -NoProfile -File scripts/Test-InstallDrift.ps1` |  |  | |
| Test-InvokeOpenClawJobDispatch | `pwsh -NoProfile -File scripts/Test-InvokeOpenClawJobDispatch.ps1` |  |  | |
| Test-LlamaCppAdapter | `pwsh -NoProfile -File scripts/Test-LlamaCppAdapter.ps1` |  |  | |
| Test-LMStudioAdapter | `pwsh -NoProfile -File scripts/Test-LMStudioAdapter.ps1` |  |  | |
| Test-ModelSelection | `pwsh -NoProfile -File scripts/Test-ModelSelection.ps1` |  |  | |
| Test-OllamaAdapter | `pwsh -NoProfile -File scripts/Test-OllamaAdapter.ps1` |  |  | |
| Test-OpenCodeCapabilityContract | `pwsh -NoProfile -File scripts/Test-OpenCodeCapabilityContract.ps1` |  |  | |
| Test-PerfProbe | `pwsh -NoProfile -File scripts/Test-PerfProbe.ps1` |  |  | |
| Test-PiCapabilityContract | `pwsh -NoProfile -File scripts/Test-PiCapabilityContract.ps1` |  |  | live Pi 3/3 |
| Test-PullProgress | `pwsh -NoProfile -File scripts/Test-PullProgress.ps1` |  |  | |
| Test-RepairLoopCapabilityContract | `pwsh -NoProfile -File scripts/Test-RepairLoopCapabilityContract.ps1` |  |  | |
| Test-SessionResume | `pwsh -NoProfile -File scripts/Test-SessionResume.ps1` |  |  | Grok hard-limit auto-capture |
| Test-StartAgentSession | `pwsh -NoProfile -File scripts/Test-StartAgentSession.ps1` |  |  | |
| Test-StartAgentWorkerJob | `pwsh -NoProfile -File scripts/Test-StartAgentWorkerJob.ps1` |  |  | |
| Test-StoragePreflight | `pwsh -NoProfile -File scripts/Test-StoragePreflight.ps1` |  |  | |
| Test-TaskRoute | `pwsh -NoProfile -File scripts/Test-TaskRoute.ps1` |  |  | |
| Test-ToolProxyLifecycle | `pwsh -NoProfile -File scripts/Test-ToolProxyLifecycle.ps1` |  |  | |
| Test-Uninstall | `pwsh -NoProfile -File scripts/Test-Uninstall.ps1` |  |  | |
| Test-WorkspaceContract | `pwsh -NoProfile -File scripts/Test-WorkspaceContract.ps1` |  |  | |
| pytest memory-service and tool-proxy | `python -m pytest memory-service/tests tool-proxy/tests -q` |  |  | second vector DB |
| B: parser | Test-SessionResume.ps1 |  |  | |
| B: one-turn packet | Test-SessionResume.ps1 |  |  | |
| B: SESSION_STATE denied, RESUME_PACKET only | Test-SessionResume.ps1 |  |  | |
| B: atomic route preserve | Test-SessionResume.ps1 |  |  | |
| B: worker task prepend | Test-SessionResume.ps1 |  |  | |
| B: Pi instruction unchanged | Test-SessionResume.ps1 |  |  | live Pi 3/3 |
| B: temp-home skills | Test-SessionResume.ps1 |  |  | |
| B: suite pass sentence | `All session resume checks passed` |  |  | |
| C: pi-worker certificate | `pwsh -NoProfile -File .\scripts\Start-AgentSession.ps1 -Harness pi-worker -DownloadConfirmed` |  |  | inheriting another PC's certificate; dsh |
| D: memory | port 12346 / optional `ai-memory-start` |  |  | a failed coding door; second vector DB; LangGraph-as-coding-loop |

These stay `Not claimed` on a green run, in their own rows if you need them spelled out. Do not move them to PASS because unit tests passed:

- dsh
- LangGraph-as-coding-loop
- second vector DB
- Grok hard-limit auto-capture
- inheriting another PC's certificate
