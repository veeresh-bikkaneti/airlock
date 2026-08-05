# Start-AI.ps1 — Start local AI platform with Ollama (hardened single-instance)
# Usage: .\Start-AI.ps1 [-Model <name>] [-Port <port>] [-SkipVault] [-Force] [-StrictPort] [-NoAutoInstallOllama]
param(
    [string]$Model = "qwen2.5-coder:7b",
    [int]$Port = 0,
    [switch]$SkipVault,
    [switch]$Force,
    [switch]$StrictPort,
    [switch]$NoAutoInstallOllama
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlatformDir = "$env:USERPROFILE\.ai-platform"
$LogDir = "$PlatformDir\logs"
$StateDir = "$PlatformDir\state"
$ConfigDir = "$PlatformDir\config"
$DefaultPort = 12345

foreach ($dir in @($LogDir, $StateDir, $ConfigDir)) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

$LogFile = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')

function Write-AuditLog {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('STARTED','SUCCESS','WARNING','FAILED')][string]$Result,
        [string]$Provider = "ollama",
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
        provider     = $Provider
        model        = $ModelName
        endpoint     = $Endpoint
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
}

# Load model acquisition module (requires Write-AuditLog)
. "$PSScriptRoot\Get-ModelAcquisition.ps1"

function Test-OllamaPort {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        return $c.GetAsync("http://127.0.0.1:$Port/api/tags").Result.IsSuccessStatusCode
    } catch { return $false }
}

function Get-PortOwner {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue | Select-Object -First 1
    if ($conn) {
        $proc = Get-Process -Id $conn.OwningProcess -EA SilentlyContinue
        if ($proc) {
            $tag = if ($proc.Path -like "*Ollama*") { " [Ollama]" } else { "" }
            return "PID $($proc.Id) ($($proc.Name))$tag"
        }
    }
    return "Unknown"
}

function Stop-AllOllama {
    param([switch]$Silent)
    $killed = @()
    $appProcs = Get-Process -Name "ollama app" -ErrorAction SilentlyContinue
    $serveProcs = Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike "*ollama app*" }
    foreach ($p in $appProcs) {
        if (-not $Silent) { Write-Host "  Killing ollama app (PID $($p.Id))" -ForegroundColor Yellow }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $killed += "ollama app:$($p.Id)"
    }
    Start-Sleep -Milliseconds 500
    foreach ($p in $serveProcs) {
        if (-not $Silent) { Write-Host "  Killing ollama serve (PID $($p.Id))" -ForegroundColor Yellow }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $killed += "ollama:$($p.Id)"
    }
    Start-Sleep 3
    $survivors = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
    if ($survivors) {
        if (-not $Silent) { Write-Host "  Force-terminating surviving processes..." -ForegroundColor Red }
        taskkill /F /IM "ollama app.exe" 2>$null | Out-Null
        taskkill /F /IM "ollama.exe" 2>$null | Out-Null
        Start-Sleep 2
        $survivors = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
    }
    if ($survivors) {
        Write-Host "  ERROR: Cannot kill Ollama processes. PIDs: $($survivors.Id -join ',')" -ForegroundColor Red
        return $false
    }
    if ($killed.Count -gt 0) {
        if (-not $Silent) { Write-Host "  Killed $($killed.Count) process(es)" -ForegroundColor Green }
    }
    return $true
}

function Assert-SingleInstance {
    $allOllama = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    $allApp = Get-Process -Name "ollama app" -ErrorAction SilentlyContinue
    $totalCount = ($allOllama | Measure-Object).Count + ($allApp | Measure-Object).Count
    if ($totalCount -gt 1) {
        Write-Host "  WARNING: $totalCount Ollama processes detected (possible duplicate instances)" -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Test-FirewallRule {
    param([Parameter(Mandatory)][int]$Port)
    $ruleName = "AI-Platform-Ollama-Block-$Port"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    return $null -ne $existing
}

function Set-FirewallGuard {
    param([Parameter(Mandatory)][int]$Port)
    $ruleName = "AI-Platform-Ollama-Block-$Port"
    if (Test-FirewallRule $Port) {
        Write-Host "  Firewall rule '$ruleName' already exists" -ForegroundColor Green
        return
    }
    try {
        New-NetFirewallRule -DisplayName $ruleName `
            -Direction Inbound `
            -Action Block `
            -Protocol TCP `
            -LocalPort $Port `
            -RemoteAddress Any `
            -Profile Any `
            -Description "Block external access to Ollama on port $Port - AI Platform security" `
            -ErrorAction Stop | Out-Null
        Write-Host "  Firewall: Blocked inbound on port $Port" -ForegroundColor Green
        Write-AuditLog -Action "FirewallGuard" -Result "SUCCESS" -Message "Blocked inbound port $Port" -Detail "Rule: $ruleName"
    } catch {
        Write-Host "  Firewall: Could not create rule (needs admin?). Run as admin or create manually:" -ForegroundColor Yellow
        Write-Host "    New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Action Block -Protocol TCP -LocalPort $Port" -ForegroundColor Gray
        Write-AuditLog -Action "FirewallGuard" -Result "WARNING" -Message "Could not create firewall rule" -Detail $_.Exception.Message
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AI Platform Starting (Hardened)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-AuditLog -Action "PlatformStart" -Result "STARTED" -Message "Starting hardened AI platform" -Detail "Model: $Model StrictPort: $StrictPort"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: PowerShell 7+ required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Write-AuditLog -Action "PlatformStart" -Result "FAILED" -Message "PowerShell version too old" -Detail "$($PSVersionTable.PSVersion)"
    exit 1
}

Write-AuditLog -Action "PowerShellCheck" -Result "SUCCESS" -Message "PowerShell $($PSVersionTable.PSVersion)"

if (-not $NoAutoInstallOllama) {
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        if (-not (Install-OllamaIfMissing)) {
            exit 1
        }
    }
}

# Perform a quick system resource check to ensure we have enough RAM and (optional) GPU memory before loading a large model.
Write-Host "Resource check..." -ForegroundColor Yellow
$resources = Test-ResourceAvailability
Write-Host "  RAM: $($resources.FreeMemGB) GB free / $($resources.TotalMemGB) GB ($($resources.MemPctFree)% free)" -ForegroundColor $(if ($resources.MemOk) { "Green" } else { "Red" })
if ($resources.GpuTotalGB -ne "N/A") {
    Write-Host "  GPU: $($resources.GpuFreeGB) GB free / $($resources.GpuTotalGB) GB" -ForegroundColor $(if ($resources.GpuOk) { "Green" } else { "Red" })
}
if (-not $resources.MemOk) {
    Write-Host "  WARNING: Low memory (<20% free). Model loading may fail." -ForegroundColor Yellow
    Write-AuditLog -Action "ResourceCheck" -Result "WARNING" -Message "Low RAM" -Detail "$($resources.MemPctFree)% free"
}
if ($resources.GpuTotalGB -ne "N/A" -and -not $resources.GpuOk) {
    Write-Host "  WARNING: Low VRAM (<4GB free). Use a smaller model." -ForegroundColor Yellow
    Write-AuditLog -Action "ResourceCheck" -Result "WARNING" -Message "Low VRAM" -Detail "$($resources.GpuFreeGB) GB free"
}

$availableGB = Get-ModelSizingCeilingGB -Resources $resources
$gpuDesc = if ($resources.GpuTotalGB -ne "N/A") { "a $($resources.GpuTotalGB) GB GPU" } else { "no dedicated GPU" }
Write-AuditLog -Action "HardwareProfile" -Result "SUCCESS" `
    -Message "Detected $($resources.TotalMemGB) GB RAM, $($resources.CpuCores) CPU cores, $gpuDesc - model size ceiling $([math]::Round($availableGB,1)) GB" `
    -Detail "TotalMemGB=$($resources.TotalMemGB) FreeMemGB=$($resources.FreeMemGB) CpuCores=$($resources.CpuCores) GpuTotalGB=$($resources.GpuTotalGB) GpuFreeGB=$($resources.GpuFreeGB)"

Write-Host ""
Write-Host "Single-instance enforcement..." -ForegroundColor Yellow
$existingPort = $null
$portScanList = @(11434) + (12345..12350)
foreach ($p in $portScanList) {
    if (Test-OllamaPort $p) { $existingPort = $p; break }
}

if ($existingPort -and -not $Force) {
    Write-Host "  Found Ollama on port $existingPort" -ForegroundColor Green
    $LivePort = $existingPort
    if (-not (Assert-SingleInstance)) {
        Write-Host "  Multiple instances detected! Use -Force to reset, or ai-stop first." -ForegroundColor Yellow
        Write-AuditLog -Action "InstanceCheck" -Result "WARNING" -Message "Multiple Ollama processes" -Detail "Existing port: $existingPort"
    }
} elseif ($existingPort -and $Force) {
    Write-Host "  Found Ollama on port $existingPort — Force: killing for clean restart" -ForegroundColor Yellow
    Write-AuditLog -Action "InstanceEnforce" -Result "STARTED" -Message "Force-killing existing instances" -Detail "Port: $existingPort"
    if (-not (Stop-AllOllama)) {
        Write-Host "  ERROR: Cannot kill existing Ollama. Aborting." -ForegroundColor Red
        Write-AuditLog -Action "InstanceEnforce" -Result "FAILED" -Message "Cannot kill Ollama"
        exit 1
    }
    Write-Host "  All instances killed" -ForegroundColor Green
    Write-AuditLog -Action "InstanceEnforce" -Result "SUCCESS" -Message "All Ollama processes killed"
    $LivePort = $null
} else {
    $rogueProcs = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
    if ($rogueProcs) {
        Write-Host "  Ollama processes found but not responding — killing stale instances" -ForegroundColor Yellow
        Stop-AllOllama | Out-Null
        Write-AuditLog -Action "InstanceEnforce" -Result "SUCCESS" -Message "Killed stale Ollama processes"
    }
    $LivePort = $null
}

if (-not $LivePort) {
    $TargetPort = if ($Port -gt 0) { $Port } else { $DefaultPort }
    $conn = Get-NetTCPConnection -LocalPort $TargetPort -State Listen -EA SilentlyContinue | Select-Object -First 1
    if ($conn -and -not $Force) {
        $owner = Get-PortOwner $TargetPort
        Write-Host "Port $TargetPort is in use by: $owner" -ForegroundColor Yellow
        $choice = Read-Host "[K]ill it / [P]ick next port / [Q]uit"
        if ($choice -eq "K") { Stop-Process -Id $conn.OwningProcess -Force; Start-Sleep 2 }
        elseif ($choice -eq "P") { $TargetPort++ }
        else { Write-AuditLog -Action "PlatformStart" -Result "FAILED" -Message "User aborted — port conflict"; exit 1 }
    }
    if ($conn -and $Force) { Stop-Process -Id $conn.OwningProcess -Force; Start-Sleep 2 }

    $env:OLLAMA_HOST = "127.0.0.1:$TargetPort"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName      = "ollama"
    $psi.Arguments     = "serve"
    $psi.UseShellExecute          = $false
    $psi.RedirectStandardOutput   = $true
    $psi.RedirectStandardError    = $true
    $psi.EnvironmentVariables["OLLAMA_HOST"] = "127.0.0.1:$TargetPort"
    $psi.EnvironmentVariables["OLLAMA_NO_CLOUD"] = "true"
    $psi.EnvironmentVariables["OLLAMA_CONTEXT_LENGTH"] = "32768"
    [System.Diagnostics.Process]::Start($psi) | Out-Null

    Write-Host "Starting Ollama on port $TargetPort (waiting up to 20s)..." -ForegroundColor Yellow
    Write-AuditLog -Action "OllamaStart" -Result "STARTED" -Message "Launching Ollama on port $TargetPort"
    $elapsed = 0
    while ($elapsed -lt 20) {
        if (Test-OllamaPort $TargetPort) { $LivePort = $TargetPort; break }
        Start-Sleep 2; $elapsed += 2
    }
# No existing Ollama instance detected (or we killed it). Choose a port and launch a fresh Ollama server.
if (-not $LivePort) {
        Write-Host "ERROR: Ollama did not start." -ForegroundColor Red
        Write-AuditLog -Action "OllamaStart" -Result "FAILED" -Message "Ollama did not respond within 20s" -Detail "Port: $TargetPort"
        exit 1
    }
}

# If the user requested a strict default port (12345) but Ollama is running on another port, offer to restart on the default.
if ($StrictPort -and $LivePort -ne $DefaultPort -and $Port -eq 0) {
    Write-Host "  StrictPort: Ollama on $LivePort but expected $DefaultPort. Kill and restart? (y/n)" -ForegroundColor Yellow
    $confirm = Read-Host
    if ($confirm -eq "y") {
        Stop-AllOllama | Out-Null
        $TargetPort = $DefaultPort
        $env:OLLAMA_HOST = "127.0.0.1:$TargetPort"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName      = "ollama"
        $psi.Arguments     = "serve"
        $psi.UseShellExecute          = $false
        $psi.RedirectStandardOutput   = $true
        $psi.RedirectStandardError    = $true
        $psi.EnvironmentVariables["OLLAMA_HOST"] = "127.0.0.1:$TargetPort"
        $psi.EnvironmentVariables["OLLAMA_NO_CLOUD"] = "true"
    $psi.EnvironmentVariables["OLLAMA_CONTEXT_LENGTH"] = "32768"
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        Start-Sleep 5
        if (Test-OllamaPort $TargetPort) { $LivePort = $TargetPort }
    }
}

Write-AuditLog -Action "OllamaDetected" -Result "SUCCESS" -Message "Ollama ready" -Endpoint "http://127.0.0.1:$LivePort/v1" -Detail "Port: $LivePort"

# Auto-select a model that fits available hardware, unless the caller pinned one explicitly with -Model.
if (-not $PSBoundParameters.ContainsKey('Model')) {
    $Model = Select-BestModel -AvailableGB $availableGB -Resources $resources -GpuDesc $gpuDesc -ScriptDir $ScriptDir -LivePort $LivePort
}

$env:OLLAMA_HOST     = "127.0.0.1:$LivePort"
$env:OPENAI_API_KEY  = "ollama"
$env:OPENAI_BASE_URL = "http://127.0.0.1:$LivePort/v1"

# Block inbound traffic to the Ollama port from external sources (defense in depth).
Set-FirewallGuard -Port $LivePort

$portState = [ordered]@{
    started    = [DateTime]::UtcNow.ToString("o")
    port       = $LivePort
    model      = $Model
    ollamaHost = "127.0.0.1:$LivePort"
}
$portState | ConvertTo-Json | Set-Content "$PlatformDir\.active-port.json" -Encoding utf8NoBOM

$providerState = [ordered]@{
    provider = "ollama"
    model    = $Model
    endpoint = "http://127.0.0.1:$LivePort/v1"
    source   = "local"
    reason   = "Local provider available"
    selected = [DateTime]::UtcNow.ToString("o")
}
$providerState | ConvertTo-Json | Set-Content "$StateDir\active-provider.json" -Encoding utf8NoBOM

Write-AuditLog -Action "ProviderSelected" -Result "SUCCESS" -Provider "ollama" -ModelName $Model -Endpoint "http://127.0.0.1:$LivePort/v1" -Message "Local provider selected"

# Verify the optional secret vault (AIVault) is available for cloud fallback credentials.
if (-not $SkipVault) {
# Enforce that only a single Ollama instance is running. Detect existing instances and decide whether to reuse, kill, or start fresh.
Write-Host ""
    Write-Host "Checking secret vault..." -ForegroundColor Yellow
    try {
        $vaultInfo = Get-SecretVault -Name AIVault -ErrorAction Stop
        Write-Host "  AIVault accessible" -ForegroundColor Green
        Write-AuditLog -Action "VaultCheck" -Result "SUCCESS" -Message "AIVault accessible"
    } catch {
        Write-Host "  WARNING: AIVault not registered. Cloud fallback will not work." -ForegroundColor Yellow
        Write-AuditLog -Action "VaultCheck" -Result "WARNING" -Message "AIVault not found"
    }
}

Write-Host ""
Write-Host "Checking model: $Model" -ForegroundColor Yellow
$modelPullPending = Start-ModelAcquisitionPull -Model $Model -LivePort $LivePort -LogFile $LogFile

# Final status summary for the user, showing endpoint, model, and security posture.
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
if ($modelPullPending) {
    Write-Host "  AI PLATFORM STARTING (model pulling in background)" -ForegroundColor Yellow
} else {
    Write-Host "  AI PLATFORM READY (Hardened)" -ForegroundColor Green
}
Write-Host "  Endpoint: http://127.0.0.1:$LivePort/v1" -ForegroundColor White
if ($modelPullPending) {
    Write-Host "  Model   : $Model pulling in background — will auto-start when ready; check today's log at $LogFile for progress" -ForegroundColor Yellow
} else {
    Write-Host "  Model   : $Model" -ForegroundColor White
}
Write-Host "  Bind    : 127.0.0.1 ONLY (no external)" -ForegroundColor White
Write-Host "  Firewall: Inbound port $LivePort BLOCKED" -ForegroundColor $(if (Test-FirewallRule $LivePort) { "Green" } else { "Yellow" })
Write-Host "  Logs    : $LogFile" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Write-AuditLog -Action "PlatformStart" -Result "SUCCESS" -Message "AI platform ready" -ModelName $Model -Endpoint "http://127.0.0.1:$LivePort/v1"

# Load helper functions into the user's PowerShell session for easy commands.
if (Test-Path "$ScriptDir\profile-helpers.ps1") {
    . "$ScriptDir\profile-helpers.ps1"
}