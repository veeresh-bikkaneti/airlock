# Stop-AI.ps1 — Shut down local AI platform (hardened single-instance)
# Usage: .\Stop-AI.ps1 [-KeepLogs] [-CleanFirewall]
#   -KeepLogs         : Preserve the audit logs (default keeps them)
#   -CleanFirewall    : Remove the inbound‑blocking firewall rule created by ai-start
param(
    [switch]$KeepLogs,          # Preserve logs flag (kept for backwards compatibility)
    [switch]$CleanFirewall       # Remove firewall rule when stopping
)

# ------------------------------------------------------------
# Global settings – paths used throughout the script
# ------------------------------------------------------------
$ErrorActionPreference = "Stop"               # Abort on any error
$PlatformDir = "$env:USERPROFILE\.ai-platform"   # Base directory for the platform
$LogDir = "$PlatformDir\logs"                # Location of audit logs
$StateDir = "$PlatformDir\state"              # Where session state files live
$LogFile = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
$ActiveProviderPath = "$StateDir\active-provider.json"
$ActiveBackend = "ollama"
if (Test-Path $ActiveProviderPath) {
    try {
        $ActiveBackend = (Get-Content $ActiveProviderPath -Raw | ConvertFrom-Json).provider
    } catch { $ActiveBackend = "ollama" }
}

# ------------------------------------------------------------
# Helper: Structured audit logging (mirrors Start-AI)
# ------------------------------------------------------------
function Write-AuditLog {
    param(
        [Parameter(Mandatory)][string]$Action,                       # Action name (e.g., PlatformShutdown)
        [Parameter(Mandatory)][ValidateSet('STARTED','SUCCESS','WARNING','FAILED')][string]$Result, # Result code
        [string]$Message = "",                                      # Human‑readable message
        [string]$Detail = ""                                        # Optional technical details (e.g., PIDs)
    )
    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        user         = $env:USERNAME
        host         = $env:COMPUTERNAME
        action       = $Action
        result       = $Result
        provider     = "ollama"
        model        = ""
        endpoint     = ""
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
}

# ------------------------------------------------------------
# UI – clear visual banner for the user
# ------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  Stopping AI Platform (Hardened)" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow

Write-AuditLog -Action "PlatformShutdown" -Result "STARTED" -Message "Shutting down"

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
    $appProcs  = Get-Process -Name "ollama app" -ErrorAction SilentlyContinue   # System‑tray UI process
    $serveProcs = Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike "*ollama app*" } # Server process
    $allProcs = @($appProcs) + @($serveProcs) | Where-Object { $_ -ne $null }

    if ($allProcs.Count -gt 0) {
        $pids = ($allProcs | ForEach-Object { $_.Id }) -join ','
        Write-Host "  Found $($allProcs.Count) Ollama process(es): PID $pids" -ForegroundColor Yellow

        # Stop the tray UI first – it would otherwise respawn the server
        foreach ($p in $appProcs) {
            Write-Host "  Stopping ollama app (PID $($p.Id))" -ForegroundColor Yellow
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500

        # Then stop the server processes
        foreach ($p in $serveProcs) {
            Write-Host "  Stopping ollama serve (PID $($p.Id))" -ForegroundColor Yellow
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }

        # Give the OS a moment – sometimes a child process lingers
        Start-Sleep 3
        $survivors = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
        if ($survivors) {
            Write-Host "  Force‑terminating surviving processes..." -ForegroundColor Red
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

# ------------------------------------------------------------
# 2️⃣ Clear environment variables – ensures a clean state for next start
# ------------------------------------------------------------
$env:OLLAMA_HOST     = ""
$env:OPENAI_API_KEY  = ""
$env:OPENAI_BASE_URL = ""

# ------------------------------------------------------------
# 3️⃣ Delete session state files (active‑port.json, active‑provider.json)
# ------------------------------------------------------------
$ports = @("$PlatformDir\.active-port.json", "$StateDir\active-provider.json")
foreach ($p in $ports) {
    if (Test-Path $p) { Remove-Item $p -Force }
}

Write-Host "  Session state cleared" -ForegroundColor Green

# ------------------------------------------------------------
# 4️⃣ (Optional) Remove the firewall rule that blocked inbound access to Ollama
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Final audit log entry for a successful shutdown
# ------------------------------------------------------------
Write-AuditLog -Action "PlatformShutdown" -Result "SUCCESS" -Message "Shutdown complete"

# ------------------------------------------------------------
# UI – final information for the user
# ------------------------------------------------------------
Write-Host ""
Write-Host "  Logs: $LogFile" -ForegroundColor Gray
Write-Host ""

if (-not $KeepLogs) {
    Write-Host "  Logs are preserved. Use -KeepLogs to skip this message." -ForegroundColor DarkGray
}