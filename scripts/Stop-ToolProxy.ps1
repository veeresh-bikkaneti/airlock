# Stop-ToolProxy.ps1 — Stop the Airlock tool-call proxy
# Usage: .\Stop-ToolProxy.ps1 [-CleanFirewall]
param(
    [switch]$CleanFirewall,
    [string]$PlatformDir = "$env:USERPROFILE\.ai-platform"
)

$ErrorActionPreference = "Stop"
$LogDir = "$PlatformDir\logs"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
$statePath = "$PlatformDir\.tool-proxy-port.json"

# AIRLOCK_DEEP_REVIEW_e5121b4.md PROXY-004: a bare PID from the state file is
# not proof of identity - Windows recycles PIDs, so a stale state file could
# point Stop-Process at an unrelated process that happens to reuse the same
# ID. Confirm the process is actually this proxy (its own uvicorn command
# line) before ever calling Stop-Process on it.
function Test-ToolProxyProcessIdentity {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine
    } catch {
        return $false
    }
    return $cmdLine -and ($cmdLine -match "uvicorn") -and ($cmdLine -match "app\.main:app")
}

function Write-AuditLog {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('STARTED','SUCCESS','WARNING','FAILED')][string]$Result,
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
        endpoint     = ""
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
}

Write-Host ""
Write-Host "Stopping Airlock tool-proxy..." -ForegroundColor Yellow
Write-AuditLog -Action "ToolProxyStop" -Result "STARTED" -Message "Stopping tool-proxy"

if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    $proc = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
    if ($proc -and (Test-ToolProxyProcessIdentity -ProcessId $state.pid)) {
        Stop-Process -Id $state.pid -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped tool-proxy (PID $($state.pid))" -ForegroundColor Green
        Write-AuditLog -Action "ToolProxyStop" -Result "SUCCESS" -Message "Process stopped" -Detail "PID: $($state.pid)"
    } elseif ($proc) {
        Write-Host "  PID $($state.pid) in state file is not the tool-proxy (stale/recycled PID) - not touching it" -ForegroundColor Yellow
        Write-AuditLog -Action "ToolProxyStop" -Result "WARNING" -Message "PID identity mismatch, refused to stop" -Detail "PID: $($state.pid)"
    } else {
        Write-Host "  No running tool-proxy process found (stale state)" -ForegroundColor Gray
    }
    Remove-Item $statePath -Force
} else {
    Write-Host "  No active tool-proxy session" -ForegroundColor Gray
}

if ($CleanFirewall) {
    $rules = Get-NetFirewallRule -DisplayName "AI-Platform-ToolProxy-Block-*" -ErrorAction SilentlyContinue
    if ($rules) {
        foreach ($rule in $rules) {
            Write-Host "  Removing firewall rule: $($rule.DisplayName)" -ForegroundColor Yellow
            Remove-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction SilentlyContinue
        }
        Write-Host "  Firewall rules cleaned" -ForegroundColor Green
    }
}

Write-AuditLog -Action "ToolProxyStop" -Result "SUCCESS" -Message "Shutdown complete"
Write-Host ""
