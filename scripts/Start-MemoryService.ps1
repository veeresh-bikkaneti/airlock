# Start-MemoryService.ps1 — Start the Airlock memory-service (FastAPI, plain Python venv)
# Usage: .\Start-MemoryService.ps1 [-Port <port>] [-Force]
# Opt-in component: use ai-memory-start (via profile-helpers.ps1) rather than
# calling this directly. Deployed under $PlatformDir\memory-service by setup.ps1.
param(
    [int]$Port = 0,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PlatformDir = "$env:USERPROFILE\.ai-platform"
$LogDir = "$PlatformDir\logs"
$StateDir = "$PlatformDir\state"
$AppDir = "$PlatformDir\memory-service"
$DefaultPort = 12346

foreach ($dir in @($LogDir, $StateDir)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
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
        provider     = "memory-service"
        model        = ""
        endpoint     = $Endpoint
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
}

function Test-MemoryServicePort {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        return $c.GetAsync("http://127.0.0.1:$Port/health").Result.IsSuccessStatusCode
    } catch { return $false }
}

function Set-FirewallGuard {
    param([Parameter(Mandatory)][int]$Port)
    $ruleName = "AI-Platform-Memory-Block-$Port"
    if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
        Write-Host "  Firewall rule '$ruleName' already exists" -ForegroundColor Green
        return
    }
    try {
        New-NetFirewallRule -DisplayName $ruleName `
            -Direction Inbound -Action Block -Protocol TCP -LocalPort $Port -RemoteAddress Any -Profile Any `
            -Description "Block external access to memory-service on port $Port - AI Platform security" `
            -ErrorAction Stop | Out-Null
        Write-Host "  Firewall: Blocked inbound on port $Port" -ForegroundColor Green
        Write-AuditLog -Action "FirewallGuard" -Result "SUCCESS" -Message "Blocked inbound port $Port" -Detail "Rule: $ruleName"
    } catch {
        Write-Host "  Firewall: Could not create rule (needs admin?)." -ForegroundColor Yellow
        Write-AuditLog -Action "FirewallGuard" -Result "WARNING" -Message "Could not create firewall rule" -Detail $_.Exception.Message
    }
}

function Write-MemoryServiceState {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][int]$ProcessId)
    $state = [ordered]@{
        started = [DateTime]::UtcNow.ToString("o")
        port    = $Port
        pid     = $ProcessId
        endpoint = "http://127.0.0.1:$Port"
    }
    $state | ConvertTo-Json | Set-Content "$PlatformDir\.memory-port.json" -Encoding utf8NoBOM
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Airlock Memory Service Starting" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-AuditLog -Action "MemoryServiceStart" -Result "STARTED" -Message "Starting memory-service"

if (-not (Test-Path "$AppDir\app\main.py")) {
    Write-Host "ERROR: memory-service app not found at $AppDir. Re-run setup.ps1 from the repo." -ForegroundColor Red
    Write-AuditLog -Action "MemoryServiceStart" -Result "FAILED" -Message "App not deployed" -Detail $AppDir
    exit 1
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: python not found on PATH. Install Python 3.10+ first." -ForegroundColor Red
    Write-AuditLog -Action "MemoryServiceStart" -Result "FAILED" -Message "python not found"
    exit 1
}

$TargetPort = if ($Port -gt 0) { $Port } else { $DefaultPort }

$statePath = "$PlatformDir\.memory-port.json"
if (-not $Force -and (Test-Path $statePath)) {
    $existing = Get-Content $statePath -Raw | ConvertFrom-Json
    if ((Get-Process -Id $existing.pid -ErrorAction SilentlyContinue) -and (Test-MemoryServicePort $existing.port)) {
        Write-Host "  memory-service already running and healthy on port $($existing.port)" -ForegroundColor Green
        Set-FirewallGuard -Port $existing.port
        Write-AuditLog -Action "MemoryServiceDetected" -Result "SUCCESS" -Message "Reused existing healthy process" -Endpoint "http://127.0.0.1:$($existing.port)"
        exit 0
    }
}

$venvPython = "$AppDir\.venv\Scripts\python.exe"
if (-not (Test-Path $venvPython)) {
    Write-Host "  Creating venv and installing dependencies (first run only)..." -ForegroundColor Yellow
    python -m venv "$AppDir\.venv"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: failed to create venv." -ForegroundColor Red
        Write-AuditLog -Action "MemoryServiceStart" -Result "FAILED" -Message "venv creation failed"
        exit 1
    }
    & $venvPython -m pip install --quiet --upgrade pip
    & $venvPython -m pip install --quiet -r "$AppDir\requirements.txt"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: pip install failed." -ForegroundColor Red
        Write-AuditLog -Action "MemoryServiceStart" -Result "FAILED" -Message "pip install failed"
        exit 1
    }
}

Write-Host "Launching memory-service on port $TargetPort..." -ForegroundColor Yellow
$proc = Start-Process -FilePath $venvPython `
    -ArgumentList @("-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$TargetPort") `
    -WorkingDirectory $AppDir -WindowStyle Hidden -PassThru

Write-Host "Waiting up to 30s for memory-service to become healthy..." -ForegroundColor Yellow
$elapsed = 0
$healthy = $false
while ($elapsed -lt 30) {
    if (Test-MemoryServicePort $TargetPort) { $healthy = $true; break }
    Start-Sleep 2; $elapsed += 2
}

if (-not $healthy) {
    Write-Host "ERROR: memory-service did not become healthy within 30s." -ForegroundColor Red
    Write-AuditLog -Action "MemoryServiceStart" -Result "FAILED" -Message "Health check timed out after 30s" -Detail "Port: $TargetPort"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

Set-FirewallGuard -Port $TargetPort
Write-MemoryServiceState -Port $TargetPort -ProcessId $proc.Id

Write-AuditLog -Action "MemoryServiceStart" -Result "SUCCESS" -Message "memory-service ready" -Endpoint "http://127.0.0.1:$TargetPort"

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  MEMORY SERVICE READY" -ForegroundColor Green
Write-Host "  Endpoint: http://127.0.0.1:$TargetPort" -ForegroundColor White
Write-Host "  Bind    : 127.0.0.1 ONLY (no external)" -ForegroundColor White
Write-Host "  Logs    : $LogFile" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  This is opt-in. Run 'ai-memory-on' to route the active provider through it." -ForegroundColor Gray
Write-Host ""

exit 0
