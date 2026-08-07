# Stop-MemoryService.ps1 — Stop the Airlock memory-service
# Usage: .\Stop-MemoryService.ps1 [-CleanFirewall]
param(
    [switch]$CleanFirewall
)

$ErrorActionPreference = "Stop"
$PlatformDir = "$env:USERPROFILE\.ai-platform"
$LogDir = "$PlatformDir\logs"
$LogFile = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
$statePath = "$PlatformDir\.memory-port.json"

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
        provider     = "memory-service"
        model        = ""
        endpoint     = ""
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
}

Write-Host ""
Write-Host "Stopping Airlock memory-service..." -ForegroundColor Yellow
Write-AuditLog -Action "MemoryServiceStop" -Result "STARTED" -Message "Stopping memory-service"

if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    $proc = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
    if ($proc) {
        Stop-Process -Id $state.pid -Force -ErrorAction SilentlyContinue
        Write-Host "  Stopped memory-service (PID $($state.pid))" -ForegroundColor Green
        Write-AuditLog -Action "MemoryServiceStop" -Result "SUCCESS" -Message "Process stopped" -Detail "PID: $($state.pid)"
    } else {
        Write-Host "  No running memory-service process found (stale state)" -ForegroundColor Gray
    }
    Remove-Item $statePath -Force
} else {
    Write-Host "  No active memory-service session" -ForegroundColor Gray
}

if ($CleanFirewall) {
    $rules = Get-NetFirewallRule -DisplayName "AI-Platform-Memory-Block-*" -ErrorAction SilentlyContinue
    if ($rules) {
        foreach ($rule in $rules) {
            Write-Host "  Removing firewall rule: $($rule.DisplayName)" -ForegroundColor Yellow
            Remove-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction SilentlyContinue
        }
        Write-Host "  Firewall rules cleaned" -ForegroundColor Green
    }
}

Write-AuditLog -Action "MemoryServiceStop" -Result "SUCCESS" -Message "Shutdown complete"
Write-Host ""
