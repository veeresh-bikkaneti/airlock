# vLLM Backend Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user with an NVIDIA GPU + Docker opt into vLLM as the local inference backend instead of Ollama, with zero changes required from any downstream consumer (`ai-code`, VS Code extension, opencode/aider configs) — everything still talks to `http://127.0.0.1:12345/v1`.

**Architecture:** `Start-AI.ps1` gains a backend-selection step that runs once (persisted to `provider-policy.json`) and, when vLLM is chosen, hands off entirely to a new `Start-VLLM.ps1` script that runs the official `vllm/vllm-openai` Docker image. Ollama's existing code path in `Start-AI.ps1` is untouched below the handoff point. Exactly one backend is ever active — this is a fork, not a merge.

**Tech Stack:** PowerShell 7+, Docker Desktop (WSL2 backend) + NVIDIA Container Toolkit, `vllm/vllm-openai` Docker image, existing JSON-lines audit log convention.

## Global Constraints

- Windows-only, PowerShell 7+ (existing check in `Start-AI.ps1:163-167` — do not weaken).
- No dual-backend-running mode. `preferredLocalProvider` in `provider-policy.json` is `"ollama"` or `"vllm"`, never both.
- Every backend must bind `127.0.0.1` only (existing security invariant — see README "Before This Platform" table).
- No Pester or other test framework is used anywhere in this repo. Match the existing convention: standalone `Test-*.ps1` scripts under `scripts/` that separate pure decision logic from live data-gathering, so the pure logic is testable without real hardware (see `scripts/Test-ModelSelection.ps1` and `Select-ModelForMemory` vs `Test-ResourceAvailability` for the pattern this repo already uses).
- Follow the existing repo convention of small, self-contained per-script `Write-AuditLog` functions (see `Stop-AI.ps1:22-42` duplicating `Start-AI.ps1:26-49` rather than sharing a module) — do not introduce a new shared module for this.
- MVP ships exactly one hardcoded default vLLM model. No model picker, no `config/models.json` changes.
- `provider-policy.json`'s live runtime copy lives at `$ConfigDir` (`$env:USERPROFILE\.ai-platform\config\provider-policy.json` — the directory `Start-AI.ps1:17,20-22` already creates). The repo's `config/policies/provider-policy.json` is the template, seed-copied on first run if the runtime copy doesn't exist yet (same pattern as `.env.template`).

---

### Task 1: Backend capability detection

**Files:**
- Create: `scripts/Get-BackendCapability.ps1`
- Create: `scripts/Test-BackendCapability.ps1`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `Test-VLLMViable(-HasNvidiaGpu <bool> -DockerRunning <bool>) -> bool` (pure, no I/O) and `Get-BackendCapability() -> [pscustomobject]@{ HasNvidiaGpu; DockerRunning; VLLMViable }` (does the actual detection). Task 3 calls `Get-BackendCapability`.

- [ ] **Step 1: Write the failing test**

Create `scripts/Test-BackendCapability.ps1`:

```powershell
# Self-check for the pure vLLM-viability decision logic in Get-BackendCapability.ps1.
# Run: pwsh -File scripts/Test-BackendCapability.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "Get-BackendCapability.ps1")

$cases = @(
    @{ name = "GPU + Docker -> viable";        gpu = $true;  docker = $true;  expect = $true }
    @{ name = "GPU only, no Docker -> not viable"; gpu = $true;  docker = $false; expect = $false }
    @{ name = "Docker only, no GPU -> not viable"; gpu = $false; docker = $true;  expect = $false }
    @{ name = "Neither -> not viable";          gpu = $false; docker = $false; expect = $false }
)

$failures = 0
foreach ($c in $cases) {
    $result = Test-VLLMViable -HasNvidiaGpu $c.gpu -DockerRunning $c.docker
    if ($result -ne $c.expect) {
        Write-Host "FAIL: $($c.name) -> got $result, expected $($c.expect)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($c.name)" -ForegroundColor Green
    }
}

if ($failures -gt 0) {
    Write-Host "$failures test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "All tests passed." -ForegroundColor Green
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -File scripts/Test-BackendCapability.ps1`
Expected: FAIL — dot-sourcing `scripts/Get-BackendCapability.ps1` errors because the file doesn't exist yet.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/Get-BackendCapability.ps1`:

```powershell
# Get-BackendCapability.ps1 — Detects whether vLLM is a viable local backend choice
# (NVIDIA GPU present + Docker Desktop running). Called by Start-AI.ps1.

function Test-VLLMViable {
    # Pure decision function, no I/O — kept separate from Get-BackendCapability
    # so it's testable without real hardware. See Test-BackendCapability.ps1.
    param(
        [Parameter(Mandatory)][bool]$HasNvidiaGpu,
        [Parameter(Mandatory)][bool]$DockerRunning
    )
    return ($HasNvidiaGpu -and $DockerRunning)
}

function Get-BackendCapability {
    # Cheap, fast signals only. The real verifier is Start-VLLM.ps1's health
    # check when it actually launches the container — if GPU passthrough
    # doesn't work despite these signals looking good, that check catches it
    # and falls back to Ollama (see Start-AI.ps1's handoff/fallback logic).
    $hasNvidiaGpu = $false
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Out-Null
            $hasNvidiaGpu = ($LASTEXITCODE -eq 0)
        } catch { $hasNvidiaGpu = $false }
    }

    $dockerRunning = $false
    try {
        docker info 2>$null | Out-Null
        $dockerRunning = ($LASTEXITCODE -eq 0)
    } catch { $dockerRunning = $false }

    [pscustomobject]@{
        HasNvidiaGpu  = $hasNvidiaGpu
        DockerRunning = $dockerRunning
        VLLMViable    = (Test-VLLMViable -HasNvidiaGpu $hasNvidiaGpu -DockerRunning $dockerRunning)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -File scripts/Test-BackendCapability.ps1`
Expected: `All tests passed.` with 4 PASS lines, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/Get-BackendCapability.ps1 scripts/Test-BackendCapability.ps1
git commit -m "feat: add vLLM backend capability detection"
```

---

### Task 2: Start-VLLM.ps1 — run vLLM as a Docker-backed local backend

**Files:**
- Create: `scripts/Start-VLLM.ps1`

**Interfaces:**
- Consumes: nothing from Task 1 directly (capability check already happened in `Start-AI.ps1` before handoff — this script assumes it's being told to run, it doesn't re-decide).
- Produces: on success, writes `$env:USERPROFILE\.ai-platform\.active-port.json` and `...\state\active-provider.json` with the **same shape** `Start-AI.ps1` writes today (`port`/`model`/`started` and `provider`/`model`/`endpoint`/`source`/`reason`/`selected` respectively) so `ai-port`/`ai-provider` helpers keep working unmodified. Exits `0` on success, non-zero on failure (Task 3's fallback logic checks `$LASTEXITCODE`).

- [ ] **Step 1: Write the script**

Create `scripts/Start-VLLM.ps1`:

```powershell
# Start-VLLM.ps1 — Start vLLM as the local AI backend (Docker, single-instance)
# Usage: .\Start-VLLM.ps1 [-Port <port>] [-Force]
# Called by Start-AI.ps1 when preferredLocalProvider = "vllm". Not meant to be
# run standalone by users — use ai-start, which handles the backend choice.
param(
    [int]$Port = 0,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PlatformDir = "$env:USERPROFILE\.ai-platform"
$LogDir = "$PlatformDir\logs"
$StateDir = "$PlatformDir\state"
$DefaultPort = 12345
$ContainerName = "ai-platform-vllm"
$DefaultModel = "Qwen/Qwen2.5-Coder-7B-Instruct-AWQ"

foreach ($dir in @($LogDir, $StateDir)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

$LogFile = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')

function Write-AuditLog {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('STARTED','SUCCESS','WARNING','FAILED')][string]$Result,
        [string]$ModelName = "",
        [string]$Endpoint = "",
        [string]$Message = "",
        [string]$Detail = ""
    )
    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        user         = $env:USERNAME
        host         = $env:COMPUTERNAME
        action       = $Action
        result       = $Result
        provider     = "vllm"
        model        = $ModelName
        endpoint     = $Endpoint
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
}

function Test-VLLMPort {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        return $c.GetAsync("http://127.0.0.1:$Port/health").Result.IsSuccessStatusCode
    } catch { return $false }
}

function Set-FirewallGuard {
    param([Parameter(Mandatory)][int]$Port)
    $ruleName = "AI-Platform-VLLM-Block-$Port"
    if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
        Write-Host "  Firewall rule '$ruleName' already exists" -ForegroundColor Green
        return
    }
    try {
        New-NetFirewallRule -DisplayName $ruleName `
            -Direction Inbound -Action Block -Protocol TCP -LocalPort $Port -RemoteAddress Any -Profile Any `
            -Description "Block external access to vLLM on port $Port - AI Platform security" `
            -ErrorAction Stop | Out-Null
        Write-Host "  Firewall: Blocked inbound on port $Port" -ForegroundColor Green
        Write-AuditLog -Action "FirewallGuard" -Result "SUCCESS" -Message "Blocked inbound port $Port" -Detail "Rule: $ruleName"
    } catch {
        Write-Host "  Firewall: Could not create rule (needs admin?)." -ForegroundColor Yellow
        Write-AuditLog -Action "FirewallGuard" -Result "WARNING" -Message "Could not create firewall rule" -Detail $_.Exception.Message
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AI Platform Starting (vLLM backend)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-AuditLog -Action "VLLMStart" -Result "STARTED" -Message "Starting vLLM backend" -ModelName $DefaultModel

$dockerRunning = $false
try { docker info 2>$null | Out-Null; $dockerRunning = ($LASTEXITCODE -eq 0) } catch { $dockerRunning = $false }
if (-not $dockerRunning) {
    Write-Host "ERROR: Docker is not running. Start Docker Desktop first." -ForegroundColor Red
    Write-AuditLog -Action "VLLMStart" -Result "FAILED" -Message "Docker not running"
    exit 1
}

$TargetPort = if ($Port -gt 0) { $Port } else { $DefaultPort }

$existing = docker ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
if ($existing -eq $ContainerName) {
    if ($Force) {
        Write-Host "  Existing vLLM container found — Force: removing for clean restart" -ForegroundColor Yellow
        docker rm -f $ContainerName 2>$null | Out-Null
    } elseif (Test-VLLMPort $TargetPort) {
        Write-Host "  vLLM already running and healthy on port $TargetPort" -ForegroundColor Green
        Write-AuditLog -Action "VLLMDetected" -Result "SUCCESS" -Message "Reused existing healthy container" -Endpoint "http://127.0.0.1:$TargetPort/v1"
        exit 0
    } else {
        Write-Host "  Existing vLLM container found but unhealthy — removing" -ForegroundColor Yellow
        docker rm -f $ContainerName 2>$null | Out-Null
    }
}

Write-Host "Launching vLLM container (model: $DefaultModel)..." -ForegroundColor Yellow
docker run -d --name $ContainerName --gpus all `
    -p "127.0.0.1:${TargetPort}:8000" `
    vllm/vllm-openai:latest `
    --model $DefaultModel --quantization awq --max-model-len 32768 --host 0.0.0.0 --port 8000 `
    2>$null | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: docker run failed to launch the vLLM container." -ForegroundColor Red
    Write-AuditLog -Action "VLLMStart" -Result "FAILED" -Message "docker run failed"
    exit 1
}

Write-Host "Waiting up to 120s for vLLM to load the model and become healthy..." -ForegroundColor Yellow
$elapsed = 0
$healthy = $false
while ($elapsed -lt 120) {
    if (Test-VLLMPort $TargetPort) { $healthy = $true; break }
    Start-Sleep 5; $elapsed += 5
}

if (-not $healthy) {
    Write-Host "ERROR: vLLM did not become healthy within 120s." -ForegroundColor Red
    Write-AuditLog -Action "VLLMStart" -Result "FAILED" -Message "Health check timed out after 120s" -Detail "Port: $TargetPort"
    docker logs $ContainerName --tail 30 2>$null | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    docker rm -f $ContainerName 2>$null | Out-Null
    exit 1
}

Set-FirewallGuard -Port $TargetPort

$portState = [ordered]@{
    started = [DateTime]::UtcNow.ToString("o")
    port    = $TargetPort
    model   = $DefaultModel
    ollamaHost = "127.0.0.1:$TargetPort"
}
$portState | ConvertTo-Json | Set-Content "$PlatformDir\.active-port.json" -Encoding utf8NoBOM

$providerState = [ordered]@{
    provider = "vllm"
    model    = $DefaultModel
    endpoint = "http://127.0.0.1:$TargetPort/v1"
    source   = "local"
    reason   = "Local vLLM provider selected"
    selected = [DateTime]::UtcNow.ToString("o")
}
$providerState | ConvertTo-Json | Set-Content "$StateDir\active-provider.json" -Encoding utf8NoBOM

Write-AuditLog -Action "VLLMStart" -Result "SUCCESS" -Message "vLLM ready" -ModelName $DefaultModel -Endpoint "http://127.0.0.1:$TargetPort/v1"

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  AI PLATFORM READY (vLLM)" -ForegroundColor Green
Write-Host "  Endpoint: http://127.0.0.1:$TargetPort/v1" -ForegroundColor White
Write-Host "  Model   : $DefaultModel" -ForegroundColor White
Write-Host "  Bind    : 127.0.0.1 ONLY (no external)" -ForegroundColor White
Write-Host "  Logs    : $LogFile" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

exit 0
```

- [ ] **Step 2: Manual verification (no automated test — requires real NVIDIA GPU + Docker Desktop)**

On a machine with an NVIDIA GPU and Docker Desktop (WSL2 backend) running:

Run: `pwsh -File scripts/Start-VLLM.ps1`
Expected: container launches, health check passes within 120s, script prints "AI PLATFORM READY (vLLM)", exit code 0. Then:

Run: `curl http://127.0.0.1:12345/v1/models`
Expected: JSON response listing `Qwen/Qwen2.5-Coder-7B-Instruct-AWQ`.

Run: `pwsh -File scripts/Start-VLLM.ps1` again (no `-Force`)
Expected: "vLLM already running and healthy" message, exits 0 immediately without relaunching.

- [ ] **Step 3: Commit**

```bash
git add scripts/Start-VLLM.ps1
git commit -m "feat: add Start-VLLM.ps1 for Docker-based vLLM backend"
```

---

### Task 3: Start-AI.ps1 — backend chooser and handoff

**Files:**
- Modify: `scripts/Start-AI.ps1:169-171` (insert new block between the existing `PowerShellCheck` audit log line and the `NoAutoInstallOllama` block)

**Interfaces:**
- Consumes: `Get-BackendCapability` from Task 1 (`scripts/Get-BackendCapability.ps1`), `Start-VLLM.ps1` from Task 2 (invoked as a child process).
- Produces: nothing new for later tasks — this is the entry point.

- [ ] **Step 1: Add the seed-copy for provider-policy.json and the backend chooser**

In `scripts/Start-AI.ps1`, after line 22 (`}` closing the `foreach ($dir in @($LogDir, $StateDir, $ConfigDir))` loop) and before line 24 (`$LogFile = ...`), add:

```powershell
$ProviderPolicyPath = Join-Path $ConfigDir "provider-policy.json"
if (-not (Test-Path $ProviderPolicyPath)) {
    $TemplatePolicyPath = Join-Path (Split-Path -Parent $ScriptDir) "config\policies\provider-policy.json"
    if (Test-Path $TemplatePolicyPath) {
        Copy-Item $TemplatePolicyPath $ProviderPolicyPath
    }
}
```

Then, in `scripts/Start-AI.ps1`, immediately after line 169
(`Write-AuditLog -Action "PowerShellCheck" -Result "SUCCESS" -Message "PowerShell $($PSVersionTable.PSVersion)"`)
and before line 171 (`if (-not $NoAutoInstallOllama) {`), add:

```powershell
# --- Backend selection (Ollama vs vLLM) — runs once, persisted to provider-policy.json ---
. "$PSScriptRoot\Get-BackendCapability.ps1"

function Get-PreferredBackend {
    param([Parameter(Mandatory)][string]$PolicyPath)
    if (-not (Test-Path $PolicyPath)) { return $null }
    $policy = Get-Content $PolicyPath -Raw | ConvertFrom-Json
    if ($policy.PSObject.Properties.Name -contains 'preferredLocalProvider') {
        return $policy.preferredLocalProvider
    }
    return $null
}

function Set-PreferredBackend {
    param(
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][ValidateSet('ollama', 'vllm')][string]$Backend
    )
    $policy = Get-Content $PolicyPath -Raw | ConvertFrom-Json
    $policy.preferredLocalProvider = $Backend
    $policy | ConvertTo-Json -Depth 10 | Set-Content $PolicyPath -Encoding utf8NoBOM
}

$Backend = Get-PreferredBackend -PolicyPath $ProviderPolicyPath
if ($Backend -notin @('ollama', 'vllm')) {
    $capability = Get-BackendCapability
    if ($capability.VLLMViable) {
        Write-Host ""
        Write-Host "NVIDIA GPU + Docker detected. Choose your local backend:" -ForegroundColor Cyan
        Write-Host "  [O] Ollama - works everywhere, broad model support (default)" -ForegroundColor Gray
        Write-Host "  [V] vLLM   - NVIDIA GPU required, faster for concurrent requests" -ForegroundColor Gray
        $choice = Read-Host "Choice [O/v]"
        $Backend = if ($choice -in @('V', 'v')) { "vllm" } else { "ollama" }
    } else {
        $Backend = "ollama"
    }
    Set-PreferredBackend -PolicyPath $ProviderPolicyPath -Backend $Backend
    Write-AuditLog -Action "BackendSelected" -Result "SUCCESS" -Provider $Backend -Message "Backend choice persisted to provider-policy.json"
}

if ($Backend -eq "vllm") {
    Write-Host "Handing off to vLLM startup..." -ForegroundColor Cyan
    & "$ScriptDir\Start-VLLM.ps1" -Port $Port -Force:$Force
    if ($LASTEXITCODE -eq 0) {
        exit 0
    }
    Write-Host "vLLM failed to start — falling back to Ollama." -ForegroundColor Yellow
    Write-AuditLog -Action "BackendFallback" -Result "WARNING" -Provider "vllm" -Message "vLLM start failed, falling back to Ollama"
}
# --- End backend selection. Everything below this point is the existing Ollama flow, unchanged. ---
```

- [ ] **Step 2: Manual verification — regression check (no NVIDIA GPU / no Docker)**

Run: `pwsh -File scripts/Start-AI.ps1`
Expected: no backend prompt appears (capability check reports not viable), `provider-policy.json` gets `preferredLocalProvider: "ollama"` written on first run, Ollama starts exactly as it did before this change. This is the critical regression check — the existing 300+ lines below the inserted block must run untouched.

Run: `pwsh -File scripts/Start-AI.ps1` a second time
Expected: no prompt (backend already persisted as `"ollama"`), same Ollama startup as before.

- [ ] **Step 3: Manual verification — NVIDIA GPU + Docker machine**

Delete `%USERPROFILE%\.ai-platform\config\provider-policy.json` to reset the choice, then:

Run: `pwsh -File scripts/Start-AI.ps1`
Expected: backend prompt appears, choosing `V` hands off to `Start-VLLM.ps1`, `ai-code`/any OpenAI-compatible client works against `http://127.0.0.1:12345/v1` with no client-side changes.

- [ ] **Step 4: Commit**

```bash
git add scripts/Start-AI.ps1
git commit -m "feat: add backend chooser and vLLM handoff to Start-AI.ps1"
```

---

### Task 4: Stop-AI.ps1 — stop whichever backend is active

**Files:**
- Modify: `scripts/Stop-AI.ps1:44-98` (the Ollama-process-killing section)

**Interfaces:**
- Consumes: `$StateDir\active-provider.json` (written by both `Start-AI.ps1` and `Start-VLLM.ps1` with a `provider` field of `"ollama"` or `"vllm"`).
- Produces: nothing for later tasks.

- [ ] **Step 1: Branch on active backend before the existing Ollama-kill logic**

In `scripts/Stop-AI.ps1`, after line 17 (`$LogFile = Join-Path $LogDir ...`), add:

```powershell
$StateDir = "$PlatformDir\state"
$ActiveProviderPath = "$StateDir\active-provider.json"
$ActiveBackend = "ollama"
if (Test-Path $ActiveProviderPath) {
    try {
        $ActiveBackend = (Get-Content $ActiveProviderPath -Raw | ConvertFrom-Json).provider
    } catch { $ActiveBackend = "ollama" }
}
```

Then wrap the existing section 1 (lines 54-98, "Identify and kill any running Ollama processes") with a check, replacing the section's opening comment and first line:

```powershell
# ------------------------------------------------------------
# 1️⃣ Stop the active backend (Ollama process kill, or vLLM container stop)
# ------------------------------------------------------------
if ($ActiveBackend -eq "vllm") {
    $running = docker ps --filter "name=ai-platform-vllm" --format "{{.Names}}" 2>$null
    if ($running -eq "ai-platform-vllm") {
        Write-Host "  Stopping vLLM container" -ForegroundColor Yellow
        docker rm -f ai-platform-vllm 2>$null | Out-Null
        Write-Host "  vLLM container stopped" -ForegroundColor Green
        Write-AuditLog -Action "VLLMStop" -Result "SUCCESS" -Message "vLLM container stopped"
    } else {
        Write-Host "  No running vLLM container found" -ForegroundColor Gray
    }
} else {
    $appProcs  = Get-Process -Name "ollama app" -ErrorAction SilentlyContinue
    $serveProcs = Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike "*ollama app*" }
    $allProcs = @($appProcs) + @($serveProcs) | Where-Object { $_ -ne $null }

    if ($allProcs.Count -gt 0) {
        $pids = ($allProcs | ForEach-Object { $_.Id }) -join ','
        Write-Host "  Found $($allProcs.Count) Ollama process(es): PID $pids" -ForegroundColor Yellow

        foreach ($p in $appProcs) {
            Write-Host "  Stopping ollama app (PID $($p.Id))" -ForegroundColor Yellow
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500

        foreach ($p in $serveProcs) {
            Write-Host "  Stopping ollama serve (PID $($p.Id))" -ForegroundColor Yellow
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }

        Start-Sleep 3
        $survivors = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
        if ($survivors) {
            Write-Host "  Force-terminating surviving processes..." -ForegroundColor Red
            taskkill /F /IM "ollama app.exe" 2>$null | Out-Null
            taskkill /F /IM "ollama.exe" 2>$null | Out-Null
            Start-Sleep 2
        }

        $final = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
        if ($final) {
            Write-Host "  ERROR: Could not kill all Ollama processes (PIDs: $($final.Id -join ','))" -ForegroundColor Red
            Write-AuditLog -Action "OllamaStop" -Result "FAILED" -Message "Ollama processes survived" -Detail "PIDs: $($final.Id -join ',')"
        } else {
            Write-Host "  All Ollama processes stopped" -ForegroundColor Green
            Write-AuditLog -Action "OllamaStop" -Result "SUCCESS" -Message "All Ollama processes stopped" -Detail "PIDs: $pids"
        }
    } else {
        Write-Host "  No Ollama processes found" -ForegroundColor Gray
    }
}
```

This replaces the file's existing lines 54-98 entirely (same Ollama logic, now nested under the `else` branch).

Also update the firewall cleanup section (existing lines 120-129) to match both rule-name patterns:

```powershell
if ($CleanFirewall) {
    $rules = Get-NetFirewallRule -DisplayName "AI-Platform-*-Block-*" -ErrorAction SilentlyContinue
    if ($rules) {
        foreach ($rule in $rules) {
            Write-Host "  Removing firewall rule: $($rule.DisplayName)" -ForegroundColor Yellow
            Remove-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction SilentlyContinue
        }
        Write-Host "  Firewall rules cleaned" -ForegroundColor Green
    }
}
```

(Changed the filter from `AI-Platform-Ollama-Block-*` to `AI-Platform-*-Block-*` so it catches the new `AI-Platform-VLLM-Block-*` rules too.)

- [ ] **Step 2: Manual verification**

With Ollama running (`active-provider.json` has `provider: "ollama"`):
Run: `pwsh -File scripts/Stop-AI.ps1`
Expected: identical behavior to before this change — Ollama processes killed.

With vLLM running (`active-provider.json` has `provider: "vllm"`):
Run: `pwsh -File scripts/Stop-AI.ps1`
Expected: "Stopping vLLM container" → container removed, `docker ps` shows nothing named `ai-platform-vllm`.

- [ ] **Step 3: Commit**

```bash
git add scripts/Stop-AI.ps1
git commit -m "feat: stop the active backend (Ollama or vLLM) in Stop-AI.ps1"
```

---

### Task 5: ai-port health check + docs

**Files:**
- Modify: `scripts/profile-helpers.ps1` (the `ai-port` function's health check)
- Modify: `docs/05-Provider-Fallback-Matrix.md`
- Modify: `README.md` (Component Guide table)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing for later tasks (final task).

- [ ] **Step 1: Fix ai-port's health check to work for both backends**

In `scripts/profile-helpers.ps1`, the `ai-port` function currently checks
`http://127.0.0.1:$($data.port)/api/tags` — that's an Ollama-only endpoint;
vLLM doesn't implement it. Both backends implement the OpenAI-compatible
`/v1/models` endpoint, so switch to that. Find:

```powershell
            if ($c.GetAsync("http://127.0.0.1:$($data.port)/api/tags").Result.IsSuccessStatusCode) {
```

Replace with:

```powershell
            if ($c.GetAsync("http://127.0.0.1:$($data.port)/v1/models").Result.IsSuccessStatusCode) {
```

- [ ] **Step 2: Manual verification**

With Ollama running: run `ai-port` in a PowerShell session that has sourced `profile-helpers.ps1` → expect `Status: HEALTHY` (unchanged from before).
With vLLM running: run `ai-port` → expect `Status: HEALTHY` (this was `UNREACHABLE` before the fix).

- [ ] **Step 3: Update docs**

In `docs/05-Provider-Fallback-Matrix.md`, update the "Normal operation" row of the Decision Table:

```
| Normal operation | Yes | No | N/A | Use local provider (Ollama or vLLM, per `preferredLocalProvider`). |
```

And add a row to the Provider Mapping table, directly under the Ollama row:

```
| vLLM | none; use placeholder `ollama` for OpenAI-compatible clients | `http://127.0.0.1:<port>/v1` | Optional alt local path — requires NVIDIA GPU + Docker Desktop. Chosen via `preferredLocalProvider: "vllm"` in provider-policy.json. |
```

In `README.md`'s Core Scripts table (under `### 🔧 Core Scripts (\`scripts/\`)`), add two rows after the `Start-AI.ps1` row:

```
| **`Start-VLLM.ps1`** | Runs vLLM (Docker) as the local backend on port 12345, health-checked and firewall-guarded like Ollama | Optional higher-throughput backend for NVIDIA GPU owners — called automatically by `Start-AI.ps1` when `preferredLocalProvider` is `vllm` |
| **`Get-BackendCapability.ps1`** | Detects whether vLLM is viable (NVIDIA GPU + Docker Desktop running) | Lets `Start-AI.ps1` only offer vLLM as a choice when it can actually work |
```

- [ ] **Step 4: Commit**

```bash
git add scripts/profile-helpers.ps1 docs/05-Provider-Fallback-Matrix.md README.md
git commit -m "fix: generalize ai-port health check for vLLM backend, update docs"
```
