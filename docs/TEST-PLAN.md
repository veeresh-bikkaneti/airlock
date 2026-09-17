# Airlock Patch Validation — Test Strategy & Plan

Run on **your Windows machine** (the ThinkPad P16 / RTX 5000 Ada 16 GB is the
evidence host). Linux validated: PowerShell parser clean on all touched
files, all new unit suites green, both patches stack-apply cleanly on
`eb65be7`. Everything below is what only Windows + your hardware can prove.

Strategy in one line: **unit → cold install → prove → land**, each phase with
exact commands, expected output, and what a failure means. Stop at the first
red phase; the triage section tells you what to send back.

---

## 0. Setup — apply both patch sets (5 min)

```powershell
git clone https://github.com/veeresh-bikkaneti/airlock.git
cd airlock
git checkout eb65be7
git apply airlock-cold-machine-fix.patch   # set 1
git apply airlock-landing-gap.patch        # set 2 (stacks on set 1)
git status --short                         # expect the 13 modified + 7 new files, no rejects
```

Do all Phase A work from this checkout. Do **not** commit anything.

---

## Phase A — Unit / static (no downloads, ~3 min)

No GPU, Docker, or network model downloads needed. Run from the repo root.

```powershell
# 1. Parser check over every touched file (must print "syntax errors: 0")
pwsh -NoProfile -Command '
$files = @("install.ps1","scripts/StoragePreflight.ps1","scripts/Test-StoragePreflight.ps1",
"scripts/Get-ModelAcquisition.ps1","scripts/Get-HuggingFaceGguf.ps1",
"scripts/Start-AgentSession.ps1","scripts/runtime-adapters/llamacpp.ps1",
"scripts/Invoke-PiCapabilityContract.ps1","scripts/agent-fail-ledger.ps1",
"scripts/Test-FailLedger.ps1","scripts/agent-perf-probe.ps1","scripts/Test-PerfProbe.ps1",
"scripts/New-AgentJobManifest.ps1","scripts/Invoke-HarnessConfigTransaction.ps1",
"scripts/Test-HarnessConfigTransaction.ps1","scripts/Invoke-OpenCodeCapabilityContract.ps1")
$bad = 0
foreach ($f in $files) {
  $errs = $null; $toks = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-Location) $f), [ref]$toks, [ref]$errs)
  if ($errs.Count -gt 0) { $bad++; Write-Host "SYNTAX FAIL: $f" -ForegroundColor Red }
}
Write-Host "syntax errors: $bad"'

# 2. New suites (each must end "...checks passed.")
pwsh -NoProfile -File scripts/Test-StoragePreflight.ps1
pwsh -NoProfile -File scripts/Test-FailLedger.ps1
pwsh -NoProfile -File scripts/Test-PerfProbe.ps1
pwsh -NoProfile -File scripts/Test-HarnessConfigTransaction.ps1

# 3. Regression suites for touched areas
pwsh -NoProfile -File scripts/Test-StartAgentSession.ps1
pwsh -NoProfile -File scripts/Test-OpenCodeCapabilityContract.ps1
pwsh -NoProfile -File scripts/Test-AgentJobHelpers.ps1
```

**Expected:** everything green **except** `Test-AgentJobHelpers.ps1`, which has
one pre-existing failure ("the host home directory is never mounted") that
fails identically on pristine `eb65be7` — a Linux path expectation, not a
patch regression. On your Windows box it may pass; either way, record the
result.

**If red:** paste the failing `FAIL:` line plus the 5 lines above it. Do not
proceed to Phase B — a unit failure means the patch is wrong, not the machine.

---

## Phase B — Cold-machine acceptance (~30–60 min)

### B1. True cold install — Windows Sandbox (recommended, ~20 min)

Windows Sandbox is a pristine Windows install that throws itself away — the
cleanest cold-machine simulator without wiping your laptop. (Needs Win
10/11 Pro/Enterprise; enable via "Turn Windows features on or off".)

```powershell
# Inside the sandbox, in Windows PowerShell 5.1 (as a real cold machine would):
Set-ExecutionPolicy Bypass -Scope Process -Force
# copy install.ps1 into the sandbox, then:
.\install.ps1
```

**Expected:** winget installs PowerShell 7, script exits 0 telling you to
re-run in `pwsh`. Then in `pwsh`: `.\install.ps1` again → winget installs
git, repo clones, `setup.ps1` deploys to `~/.ai-platform`.

**Verify:** `pwsh -c '$PSVersionTable.PSVersion'` → 7.x; `git --version`;
`Test-Path ~/.ai-platform/scripts/Start-AI.ps1` → True.

**If red:** sandbox has no winget on some SKUs — that itself is a finding
(the script's manual-install fallback should trigger; record which path ran).

### B2. llama-server auto-acquire (~5 min + download)

```powershell
pwsh -NoProfile -Command '
. .\scripts\runtime-adapters\llamacpp.ps1
$r = Get-AirlockLlamaServerBinary -PlatformDir "$env:USERPROFILE\.ai-platform"
$r | Format-List Path, Source, Reason'
```

**Expected:** `Source` is `PATH` (already installed), or `Download` with the
binary at `~/.ai-platform/bin/llama-server.exe`. On your NVIDIA box the
download flavor must be the CUDA build; sibling DLLs land next to the exe.
`Reason` explains which.

### B3. Storage preflight (live, ~1 min)

Covered by unit tests in Phase A. Live check is implicit: every GGUF/Ollama
download path now fails fast with "Only X GB free" instead of dying mid-pull.
No action unless your disk is near-full — if it is, that's the test.

### B4. Pi/Docker preflight (~2 min)

```powershell
# With Docker Desktop STOPPED:
pwsh -NoProfile -Command '
. .\scripts\Invoke-PiCapabilityContract.ps1
Test-AirlockPiPrerequisites | Format-List'
```

**Expected:** one clear sentence — Docker absent / daemon stopped / image
missing — naming the fix. **Not** a raw `docker run` stack trace.

---

## Phase C — Landing-gap acceptance (the money, ~45–90 min)

Prerequisites: Docker Desktop **running**, ~20 GB free disk, NVIDIA driver
healthy (`nvidia-smi` works). The 13 GB coding GGUF downloads once here —
that's the long pole (10–40 min depending on bandwidth).

### C1. Prove the coding door

```powershell
ai-agent-start -Harness pi-worker
```

**Expected:**
- `SIZED:` line naming the Unsloth quant chosen for your VRAM.
- Model downloads (detached; closing the terminal must not kill it).
- `THROUGHPUT: measured ~X tok/s on this hardware (tier: ...)` — on the
  RTX 5000 Ada expect `interactive`.
- `SUCCESS` and a certificate at `~/.ai-platform/state/active-agent.json`
  containing `measuredToksPerSec`.

**Then:** run it again immediately. **Expected:** fast pass from the
capability-registry cache (no re-download, no re-trial).

### C2. Fail ledger (natural, ~0 min extra)

If C1 ever fails on a transport, check
`~/.ai-platform/state/fail-ledger.jsonl` — one JSON line per failure with the
reason. Re-run `ai-agent-start`: **expected** a yellow `LEDGER:` warning
naming the prior failure, then a fresh re-proof (warning, never refusal).

### C3. Land: certificate → running agent

```powershell
# Author the manifest (only task + repo are yours; rest is secure defaults)
.\scripts\New-AgentJobManifest.ps1 -Task "Add a Pester test for <small real thing>" -RepoPath "C:\source\<scratch-repo>"

# Dry run first
.\scripts\Start-AgentWorkerJob.ps1 -JobId <printed-id> -WhatIf

# Real run (use a SCRATCH repo - the worker gets a worktree, never your main checkout)
.\scripts\Start-AgentWorkerJob.ps1 -JobId <printed-id>
```

**Expected:** `-WhatIf` prints the plan with no side effects. The real run
creates `~/.ai-platform/jobs/<id>/worktree`, runs the Pi worker bounded
(60 min / 40 tool steps defaults), and leaves an **unmerged patch** plus
`result.json` and a redacted `audit.jsonl`. It must never merge or push.

**Timing note:** author and launch within ~5 minutes of C1 — the evidence
pass TTL is 5 minutes. If the worker refuses with "not a fresh passing
verdict," re-run C1; that's the design working, not a bug.

### C4. Opencode landing (optional, ~10 min)

Requires the opencode CLI on PATH (`npm i -g opencode`).

```powershell
ai-agent-start -Harness opencode -PersistHarnessConfig
```

**Expected:** after the passing trial, `OPENCODE LANDED` + the live path of
`~/.opencode/opencode.json` now containing the `airlock` provider pointed at
your local endpoint, a timestamped backup in `state\config-backups`, and
`cd <repo>; opencode` working against the local model.

**Rollback check:** restore the backup over `opencode.json` and confirm
`opencode` no longer sees the `airlock` provider. The landing must be
reversible.

---

## Triage guide

| Symptom | Meaning | Send back |
|---|---|---|
| Phase A red | Patch bug, not hardware | Failing `FAIL:` line + 5 lines above |
| `SIZED:` picks CPU offload on the RTX box | VRAM misread (`nvidia-smi`) | `nvidia-smi` output + the SIZED line |
| GGUF download stalls/fails | Network or disk | `fail-ledger.jsonl` last line + free GB |
| Contract `FAILED`, no `LEDGER:` on retry | Ledger write failed (non-fatal) | Whether `fail-ledger.jsonl` exists |
| `THROUGHPUT: probe inconclusive` | Endpoint didn't answer `/v1/completions` | The `Reason` text + which runtime |
| Worker: "not a fresh passing verdict" | >5 min since C1 | Just re-run C1 (by design) |
| Worker produces no patch | Model too weak at this quant or task too big | `result.json` + `audit.jsonl` tail |
| Sandbox has no winget | SKU without App Installer | Which fallback message printed |

## Sign-off checklist

- [ ] Phase A green (minus the one documented pre-existing failure)
- [ ] B1: sandbox cold install reaches deployed `~/.ai-platform`
- [ ] B2: `llama-server.exe` resolved (PATH or downloaded, CUDA flavor)
- [ ] B4: stopped-Docker error is one actionable sentence
- [ ] C1: certificate published with measured tok/s; second run is cached
- [ ] C3: worker job leaves an unmerged patch, never merges/pushes
- [ ] C4 (if opencode): landed config works; rollback verified

---

## What this plan deliberately does not test

- **AIDA64-style multi-machine portability** — the vision's "any PC" claim
  needs a second, weaker box (an iGPU-only laptop is ideal). One machine
  proves the mechanism, not the portability.
- **RAM-mmap path** — your 16 GB VRAM box won't take it; needs a small-VRAM
  machine to exercise honestly.
- **Multi-hour agent loops** — bounded at 60 min by the manifest default;
  the resume/memory-service story is a separate test.
