# Start-VLLM.ps1 — Start vLLM local AI backend (Docker, single-instance)
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

function Write-VLLMState {
    param([Parameter(Mandatory)][int]$Port)
    $portState = [ordered]@{
        started = [DateTime]::UtcNow.ToString("o")
        port    = $Port
        model   = $DefaultModel
        ollamaHost = "127.0.0.1:$Port"
    }
    $portState | ConvertTo-Json | Set-Content "$PlatformDir\.active-port.json" -Encoding utf8NoBOM

    $providerState = [ordered]@{
        provider = "vllm"
        model    = $DefaultModel
        endpoint = "http://127.0.0.1:$Port/v1"
        source   = "local"
        reason   = "Local vLLM provider selected"
        selected = [DateTime]::UtcNow.ToString("o")
    }
    $providerState | ConvertTo-Json | Set-Content "$StateDir\active-provider.json" -Encoding utf8NoBOM
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
        Set-FirewallGuard -Port $TargetPort
        Write-VLLMState -Port $TargetPort
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
Write-VLLMState -Port $TargetPort

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
