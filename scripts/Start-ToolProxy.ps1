# Start-ToolProxy.ps1 — Start the Airlock tool-call proxy (FastAPI, plain Python venv)
# Usage: .\Start-ToolProxy.ps1 [-Port <port>] [-Force]
# Opt-in component: use ai-tool-proxy-start (via profile-helpers.ps1) rather than
# calling this directly. Deployed under $PlatformDir\tool-proxy by setup.ps1.
#
# Fixes unreliable tool-calling on local Ollama models (qwen2.5-coder:7b,
# qwen3-coder:30b): grammar-constrains Ollama's own /api/chat output instead of
# relying on the model's free-form tool-call template, which reproducibly fails
# on those models. See tool-proxy/app/main.py's module docstring for the full
# investigation. Point an OpenAI-compatible harness (e.g. opencode.json.template)
# at this proxy's port instead of Ollama's port directly to pick up the fix.
param(
    [int]$Port = 0,
    [switch]$Force,
    [string]$PlatformDir = "$env:USERPROFILE\.ai-platform"
)

$ErrorActionPreference = "Stop"
$LogDir = "$PlatformDir\logs"
$StateDir = "$PlatformDir\state"
$AppDir = "$PlatformDir\tool-proxy"
$DefaultPort = 12347

foreach ($dir in @($LogDir, $StateDir)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

# AIRLOCK_DEEP_REVIEW_e5121b4.md PROXY-004 (shared with Stop-ToolProxy.ps1):
# never trust a bare PID from the state file - confirm it's actually this
# proxy's own uvicorn process before treating it as ownership of the port.
function Test-ToolProxyProcessIdentity {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine
    } catch {
        return $false
    }
    return $cmdLine -and ($cmdLine -match "uvicorn") -and ($cmdLine -match "app\.main:app")
}

$LogFile = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')

function Write-AuditLog {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('STARTED','SUCCESS','WARNING','FAILED')][string]$Result,
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
        provider     = "tool-proxy"
        model        = ""
        endpoint     = $Endpoint
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
}

function Test-ToolProxyPort {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        return $c.GetAsync("http://127.0.0.1:$Port/health").Result.IsSuccessStatusCode
    } catch { return $false }
}

function Set-FirewallGuard {
    param([Parameter(Mandatory)][int]$Port)
    $ruleName = "AI-Platform-ToolProxy-Block-$Port"
    if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
        Write-Host "  Firewall rule '$ruleName' already exists" -ForegroundColor Green
        return
    }
    try {
        New-NetFirewallRule -DisplayName $ruleName `
            -Direction Inbound -Action Block -Protocol TCP -LocalPort $Port -RemoteAddress Any -Profile Any `
            -Description "Block external access to tool-proxy on port $Port - AI Platform security" `
            -ErrorAction Stop | Out-Null
        Write-Host "  Firewall: Blocked inbound on port $Port" -ForegroundColor Green
        Write-AuditLog -Action "FirewallGuard" -Result "SUCCESS" -Message "Blocked inbound port $Port" -Detail "Rule: $ruleName"
    } catch {
        Write-Host "  Firewall: Could not create rule (needs admin?)." -ForegroundColor Yellow
        Write-AuditLog -Action "FirewallGuard" -Result "WARNING" -Message "Could not create firewall rule" -Detail $_.Exception.Message
    }
}

function Write-ToolProxyState {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][int]$ProcessId)
    $state = [ordered]@{
        started  = [DateTime]::UtcNow.ToString("o")
        port     = $Port
        pid      = $ProcessId
        endpoint = "http://127.0.0.1:$Port"
    }
    $state | ConvertTo-Json | Set-Content "$PlatformDir\.tool-proxy-port.json" -Encoding utf8NoBOM
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Airlock Tool-Call Proxy Starting" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-AuditLog -Action "ToolProxyStart" -Result "STARTED" -Message "Starting tool-proxy"

if (-not (Test-Path "$AppDir\app\main.py")) {
    Write-Host "ERROR: tool-proxy app not found at $AppDir. Re-run setup.ps1 from the repo." -ForegroundColor Red
    Write-AuditLog -Action "ToolProxyStart" -Result "FAILED" -Message "App not deployed" -Detail $AppDir
    exit 1
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: python not found on PATH. Install Python 3.10+ first." -ForegroundColor Red
    Write-AuditLog -Action "ToolProxyStart" -Result "FAILED" -Message "python not found"
    exit 1
}

$TargetPort = if ($Port -gt 0) { $Port } else { $DefaultPort }

$statePath = "$PlatformDir\.tool-proxy-port.json"
if (Test-Path $statePath) {
    $existing = Get-Content $statePath -Raw | ConvertFrom-Json
    $existingAlive = (Get-Process -Id $existing.pid -ErrorAction SilentlyContinue) -and (Test-ToolProxyProcessIdentity -ProcessId $existing.pid)
    if (-not $Force -and $existingAlive -and (Test-ToolProxyPort $existing.port)) {
        Write-Host "  tool-proxy already running and healthy on port $($existing.port)" -ForegroundColor Green
        Set-FirewallGuard -Port $existing.port
        Write-AuditLog -Action "ToolProxyDetected" -Result "SUCCESS" -Message "Reused existing healthy process" -Endpoint "http://127.0.0.1:$($existing.port)"
        exit 0
    }
    if ($Force -and $existingAlive) {
        # AIRLOCK_DEEP_REVIEW_e5121b4.md PROXY-003: -Force used to skip reuse
        # without ever stopping the still-running proxy, so a replacement
        # process could fail to bind the port while the old one kept serving
        # traffic - the health check below would then pass against the OLD
        # process, and state would get overwritten with the new, dead PID.
        # Stop the old one and wait for the port to actually free before
        # launching a replacement.
        Write-Host "  -Force: stopping existing tool-proxy (PID $($existing.pid)) before relaunch..." -ForegroundColor Yellow
        Stop-Process -Id $existing.pid -Force -ErrorAction SilentlyContinue
        $waited = 0
        while ((Test-ToolProxyPort $existing.port) -and $waited -lt 10) {
            Start-Sleep 1; $waited += 1
        }
    }
}

$venvPython = "$AppDir\.venv\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    Write-Host "  Creating venv (first run only)..." -ForegroundColor Yellow
    python -m venv "$AppDir\.venv"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: failed to create venv." -ForegroundColor Red
        Write-AuditLog -Action "ToolProxyStart" -Result "FAILED" -Message "venv creation failed"
        exit 1
    }
    & $venvPython -m pip install --quiet --upgrade pip
}

# AIRLOCK_DEEP_REVIEW_e5121b4.md DEPLOY-001: dependencies used to install only
# on first venv creation, so a requirements.txt change after that point was
# silently never picked up. Track a hash of the file instead of just venv
# existence, and re-sync whenever it changes.
$reqHashFile = "$AppDir\.venv\.requirements-hash"
$reqHash = (Get-FileHash "$AppDir\requirements.txt" -Algorithm SHA256).Hash
$installedHash = if (Test-Path $reqHashFile) { (Get-Content $reqHashFile -Raw).Trim() } else { "" }
if ($installedHash -ne $reqHash) {
    Write-Host "  Syncing dependencies (requirements.txt changed or first run)..." -ForegroundColor Yellow
    & $venvPython -m pip install --quiet -r "$AppDir\requirements.txt"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: pip install failed." -ForegroundColor Red
        Write-AuditLog -Action "ToolProxyStart" -Result "FAILED" -Message "pip install failed"
        exit 1
    }
    Set-Content -Path $reqHashFile -Value $reqHash -NoNewline
}

Write-Host "Launching tool-proxy on port $TargetPort..." -ForegroundColor Yellow
$proc = Start-Process -FilePath $venvPython `
    -ArgumentList @("-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$TargetPort") `
    -WorkingDirectory $AppDir -WindowStyle Hidden -PassThru

Write-Host "Waiting up to 30s for tool-proxy to become healthy..." -ForegroundColor Yellow
$elapsed = 0
$healthy = $false
while ($elapsed -lt 30) {
    if (Test-ToolProxyPort $TargetPort) { $healthy = $true; break }
    Start-Sleep 2; $elapsed += 2
}

if (-not $healthy) {
    Write-Host "ERROR: tool-proxy did not become healthy within 30s." -ForegroundColor Red
    Write-AuditLog -Action "ToolProxyStart" -Result "FAILED" -Message "Health check timed out after 30s" -Detail "Port: $TargetPort"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

Set-FirewallGuard -Port $TargetPort
Write-ToolProxyState -Port $TargetPort -ProcessId $proc.Id

Write-AuditLog -Action "ToolProxyStart" -Result "SUCCESS" -Message "tool-proxy ready" -Endpoint "http://127.0.0.1:$TargetPort"

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  TOOL-CALL PROXY READY" -ForegroundColor Green
Write-Host "  Endpoint: http://127.0.0.1:$TargetPort" -ForegroundColor White
Write-Host "  Bind    : 127.0.0.1 ONLY (no external)" -ForegroundColor White
Write-Host "  Logs    : $LogFile" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  This is opt-in. Point your harness's baseURL at this endpoint instead of" -ForegroundColor Gray
Write-Host "  Ollama's own port to get reliable tool-calling (see opencode.json.template)." -ForegroundColor Gray
Write-Host ""

exit 0
