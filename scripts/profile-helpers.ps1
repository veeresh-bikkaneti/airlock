# profile-helpers.ps1 — Add these to your PowerShell profile
# Source this file or copy its contents into your $PROFILE
# Usage: . "$env:USERPROFILE\.ai-platform\scripts\profile-helpers.ps1"

$Script:PlatformDir = "$env:USERPROFILE\.ai-platform"

# Wrapper for the real 'ollama' binary. Prevents direct use of 'ollama serve' which would bypass the platform's safety checks.
function global:ollama {
    if ($args.Count -gt 0 -and $args[0] -eq "serve") {
        Write-Host "BLOCKED: Use ai-start instead. It manages port/state/security." -ForegroundColor Red
        Write-Host "  ai-start       # Start the platform" -ForegroundColor Gray
        Write-Host "  ai-start -Force # Kill existing and restart clean" -ForegroundColor Gray
        return
    }
    & (Get-Command ollama.exe -CommandType Application -ErrorAction Stop) @args
}

# Shortcut to launch the platform startup script with any arguments you provide.
function global:ai-start {
    & "$env:USERPROFILE\.ai-platform\scripts\Start-AI.ps1" @args
}

# Shortcut to gracefully stop the platform and clean up state.
function global:ai-stop {
    & "$env:USERPROFILE\.ai-platform\scripts\Stop-AI.ps1" @args
}

# Show the currently active Ollama port, model, and health status.
function global:ai-port {
    $file = "$env:USERPROFILE\.ai-platform\.active-port.json"
    if (Test-Path $file) {
        $data = Get-Content $file -Raw | ConvertFrom-Json
        Write-Host "Ollama running on port $($data.port)" -ForegroundColor Green
        Write-Host "Model : $($data.model)" -ForegroundColor White
        Write-Host "Started: $($data.started)" -ForegroundColor Gray

        try {
            $c = [System.Net.Http.HttpClient]::new()
            $c.Timeout = [TimeSpan]::FromSeconds(5)
            if ($c.GetAsync("http://127.0.0.1:$($data.port)/api/tags").Result.IsSuccessStatusCode) {
                Write-Host "Status: HEALTHY" -ForegroundColor Green
            } else {
                Write-Host "Status: UNREACHABLE" -ForegroundColor Red
            }
        } catch {
            Write-Host "Status: UNREACHABLE" -ForegroundColor Red
        }
    } else {
        Write-Host "No active AI session. Run ai-start first." -ForegroundColor Yellow
    }
}

# Display details about the selected AI provider (local Ollama or cloud fallback).
function global:ai-provider {
    $file = "$env:USERPROFILE\.ai-platform\state\active-provider.json"
    if (Test-Path $file) {
        $data = Get-Content $file -Raw | ConvertFrom-Json
        Write-Host "Provider: $($data.provider)" -ForegroundColor Green
        Write-Host "Model   : $($data.model)" -ForegroundColor White
        Write-Host "Endpoint: $($data.endpoint)" -ForegroundColor White
        Write-Host "Source  : $($data.source)" -ForegroundColor $(if ($data.source -eq 'local') { 'Green' } else { 'Yellow' })
        Write-Host "Reason  : $($data.reason)" -ForegroundColor Gray
    } else {
        Write-Host "No active provider. Run ai-start first." -ForegroundColor Yellow
    }
}

# Switch the active model on the running Ollama instance without restarting the platform.
function global:ai-switch {
    param(
        [Parameter(Position=0, Mandatory)]
        [string]$Model,
        [int]$Port = 0
    )
    $portFile = "$env:USERPROFILE\.ai-platform\.active-port.json"
    if (-not (Test-Path $portFile)) {
        Write-Host "No active session. Run ai-start first." -ForegroundColor Red
        return
    }
    $state = Get-Content $portFile -Raw | ConvertFrom-Json
    $currentPort = if ($Port -gt 0) { $Port } else { $state.port }

    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        $resp = $c.GetAsync("http://127.0.0.1:$currentPort/api/tags").Result
        $json = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
        $found = $json.models | Where-Object { $_.name -eq $Model }
        if ($found) {
            Write-Host "Switching to model: $Model" -ForegroundColor Green
            $env:OPENAI_API_KEY = "ollama"
            $env:OPENAI_BASE_URL = "http://127.0.0.1:$currentPort/v1"

            $newState = [ordered]@{
                started    = [DateTime]::UtcNow.ToString("o")
                port       = $currentPort
                model      = $Model
                ollamaHost = "127.0.0.1:$currentPort"
            }
            $newState | ConvertTo-Json | Set-Content $portFile -Encoding utf8NoBOM

            $providerState = [ordered]@{
                provider = "ollama"
                model    = $Model
                endpoint = "http://127.0.0.1:$currentPort/v1"
                source   = "local"
                reason   = "Model switched mid-session by user"
                selected = [DateTime]::UtcNow.ToString("o")
            }
            $providerState | ConvertTo-Json | Set-Content "$env:USERPROFILE\.ai-platform\state\active-provider.json" -Encoding utf8NoBOM

            $logFile = Join-Path "$env:USERPROFILE\.ai-platform\logs" ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
            $entry = [ordered]@{
                timestampUtc = [DateTime]::UtcNow.ToString("o")
                user         = $env:USERNAME
                host         = $env:COMPUTERNAME
                action       = "ModelSwitch"
                result       = "SUCCESS"
                provider     = "ollama"
                model        = $Model
                endpoint     = "http://127.0.0.1:$currentPort/v1"
                message      = "Model switched from $($state.model) to $Model"
                detail       = ""
            }
            ($entry | ConvertTo-Json -Compress) | Add-Content -Path $logFile -Encoding utf8
        } else {
            Write-Host "Model '$Model' not found on Ollama." -ForegroundColor Red
            Write-Host "Available models:" -ForegroundColor Gray
            $json.models | ForEach-Object { Write-Host "  - $($_.name)" -ForegroundColor Gray }
            Write-Host "Pull it with: ollama pull $Model" -ForegroundColor Gray
        }
    } catch {
        Write-Host "Cannot reach Ollama on port $currentPort" -ForegroundColor Red
    }
}

# Launch the 'aider' tool configured to talk to the current Ollama model.
function global:ai-code {
    $file = "$env:USERPROFILE\.ai-platform\state\active-provider.json"
    if (-not (Test-Path $file)) {
        Write-Host "No active session. Run ai-start first." -ForegroundColor Red
        return
    }
    $data = Get-Content $file -Raw | ConvertFrom-Json
    $modelArg = "openai/$($data.model)"
    aider --model $modelArg
}

# Convenience wrappers to start/stop the Hermes container (cloud-enabled assistant).
# Path configurable via $env:HERMES_CONTAINER_PATH (set in your PowerShell profile); falls back to Downloads.
function global:ai-hermes-start {
    $base = if ($env:HERMES_CONTAINER_PATH) { $env:HERMES_CONTAINER_PATH } else { "$env:USERPROFILE\Downloads\local AI setup\hermes-container" }
    $script = Join-Path $base "run-hermes.ps1"
    if (Test-Path $script) {
        & $script @args
    } else {
        Write-Host "Hermes container not found at: $script" -ForegroundColor Red
        Write-Host "Set `$env:HERMES_CONTAINER_PATH or place it under Downloads\local AI setup\hermes-container" -ForegroundColor Gray
    }
}

# Stop the Hermes container if it is running.
function global:ai-hermes-stop {
    $base = if ($env:HERMES_CONTAINER_PATH) { $env:HERMES_CONTAINER_PATH } else { "$env:USERPROFILE\Downloads\local AI setup\hermes-container" }
    $script = Join-Path $base "stop-hermes.ps1"
    if (Test-Path $script) {
        & $script @args
    } else {
        Write-Host "Hermes container not found at: $script" -ForegroundColor Red
    }
}

# Show the most recent audit log entries to quickly review recent actions.
function global:ai-audit-last {
    $logs = Get-ChildItem "$env:USERPROFILE\.ai-platform\logs\*.jsonl" | Sort-Object LastWriteTime -Descending
    if (-not $logs) {
        Write-Host "No audit logs found." -ForegroundColor Yellow
        return
    }
    $latest = $logs | Select-Object -First 1
    Write-Host "Latest log: $($latest.Name)" -ForegroundColor Cyan
    Write-Host "-----------------------------" -ForegroundColor DarkCyan
    $entries = Get-Content $latest.FullName -Tail 20
    foreach ($entry in $entries) {
        try {
            $obj = $entry | ConvertFrom-Json
            $color = switch ($obj.result) {
                'SUCCESS' { 'Green' }
                'WARNING' { 'Yellow' }
                'FAILED'  { 'Red' }
                default   { 'Gray' }
            }
            Write-Host "[$($obj.timestampUtc)] $($obj.action): $($obj.result)" -ForegroundColor $color
        } catch {
            Write-Host $entry -ForegroundColor Gray
        }
    }
}

# Display the provider routing policy (local vs cloud) used by the platform.
function global:ai-policy {
    $file = "$env:USERPROFILE\.ai-platform\config\policies\provider-policy.json"
    if (-not (Test-Path $file)) {
        Write-Host "No provider policy found." -ForegroundColor Yellow
        return
    }
    $data = Get-Content $file -Raw | ConvertFrom-Json
    Write-Host "Provider Policy" -ForegroundColor Cyan
    Write-Host "---------------" -ForegroundColor DarkCyan
    $data.PSObject.Properties | ForEach-Object {
        $val = if ($_.Value -is [array]) { $_.Value -join ", " } else { $_.Value }
        Write-Host "  $($_.Name): $val" -ForegroundColor White
    }
}

# List all known models from the local registry.
function global:ai-models {
    $file = "$env:USERPROFILE\.ai-platform\config\models.json"
    if (-not (Test-Path $file)) {
        Write-Host "No model registry found." -ForegroundColor Yellow
        return
    }
    $data = Get-Content $file -Raw | ConvertFrom-Json
    Write-Host "Local Models" -ForegroundColor Cyan
    Write-Host "------------" -ForegroundColor DarkCyan
    foreach ($model in $data.localModels.PSObject.Properties) {
        $m = $model.Value
        Write-Host "  $($model.Name)" -ForegroundColor Green
        Write-Host "    Size: $($m.size)  Context: $($m.contextWindow)  Role: $($m.role)" -ForegroundColor Gray
        Write-Host "    Tags: $($m.tags -join ', ')" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Fallback order: $($data.fallbackOrder -join ' -> ')" -ForegroundColor White
}

function global:ai-auth {
    $authFile = "$env:USERPROFILE\.ai-platform\config\auth.json"
    if (Test-Path $authFile) {
        Write-Host "Current auth config:" -ForegroundColor Cyan
        $auth = Get-Content $authFile -Raw | ConvertFrom-Json
        $auth.PSObject.Properties | ForEach-Object {
            $status = if ($_.Value.key) { "configured" } else { "empty" }
            $color = if ($_.Value.key) { "Green" } else { "Yellow" }
            Write-Host "  $($_.Name): $status" -ForegroundColor $color
        }
    } else {
        Write-Host "No auth.json found. Copy from template:" -ForegroundColor Yellow
        Write-Host "  Copy-Item $env:USERPROFILE\.ai-platform\config\auth.json.template $authFile" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "To set keys securely:" -ForegroundColor Cyan
    Write-Host "  ai-auth-set openrouter sk-or-..." -ForegroundColor Gray
    Write-Host "  ai-auth-set openai sk-..." -ForegroundColor Gray
}

function global:ai-auth-set {
    param([string]$Provider, [string]$Key)
    if (-not $Provider -or -not $Key) {
        Write-Host "Usage: ai-auth-set <provider> <api-key>" -ForegroundColor Yellow
        Write-Host "  Providers: openrouter, nvidia, openai, anthropic, google" -ForegroundColor Gray
        return
    }
    $authFile = "$env:USERPROFILE\.ai-platform\config\auth.json"
    $auth = if (Test-Path $authFile) { Get-Content $authFile -Raw | ConvertFrom-Json } else { @{} | ConvertFrom-Json }
    $auth.$Provider = @{ type = "api_key"; key = $Key }
    $auth | ConvertTo-Json -Depth 3 | Set-Content $authFile -Encoding utf8NoBOM
    Write-Host "API key stored for $Provider in auth.json" -ForegroundColor Green
    Write-Host "NEVER commit auth.json to git!" -ForegroundColor Red
}

function global:ai-cache {
    param([switch]$Clear)
    $cacheDir = "$env:USERPROFILE\.ai-platform\cache"
    if ($Clear) {
        if (Test-Path $cacheDir) { Remove-Item $cacheDir -Recurse -Force }
        Write-Host "Cache cleared." -ForegroundColor Green
        return
    }
    if (-not (Test-Path $cacheDir)) { New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null }
    $size = (Get-ChildItem $cacheDir -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
    Write-Host "Cache: $([math]::Round($size, 1)) MB at $cacheDir" -ForegroundColor Cyan
    Write-Host "Use ai-cache -Clear to free space" -ForegroundColor Gray
}

function global:ai-config {
    Write-Host "AI Platform Configuration" -ForegroundColor Cyan
    Write-Host "=========================" -ForegroundColor DarkCyan
    Write-Host ""

    Write-Host "Active session:" -ForegroundColor White
    $portFile = "$env:USERPROFILE\.ai-platform\.active-port.json"
    if (Test-Path $portFile) {
        $d = Get-Content $portFile -Raw | ConvertFrom-Json
        Write-Host "  Port  : $($d.port)  Model: $($d.model)" -ForegroundColor Green
    } else {
        Write-Host "  (none) — run ai-start" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Config files:" -ForegroundColor White
    $files = @(
        "$env:USERPROFILE\.ai-platform\config\models.json",
        "$env:USERPROFILE\.ai-platform\config\policies\provider-policy.json",
        "$env:USERPROFILE\.ai-platform\config\policies\commit-policy.json",
        "$env:USERPROFILE\.ai-platform\config\auth.json",
        "$env:USERPROFILE\.aider.conf.yml",
        "$env:USERPROFILE\.pi\agent\models.json",
        "$env:USERPROFILE\.opencode\opencode.json"
    )
    foreach ($f in $files) {
        $exists = Test-Path $f
        $color = if ($exists) { "Green" } else { "DarkGray" }
        $status = if ($exists) { "exists" } else { "missing" }
        Write-Host "  $status  $f" -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "Template files (copy to activate):" -ForegroundColor Gray
    Get-ChildItem "$env:USERPROFILE\.ai-platform\config\*.template" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  $($_.Name)"
    }
}

function global:ai-health {
    $portFile = "$env:USERPROFILE\.ai-platform\.active-port.json"
    if (-not (Test-Path $portFile)) {
        Write-Host "No active AI session. Run ai-start first." -ForegroundColor Yellow
        return
    }
    $state = Get-Content $portFile -Raw | ConvertFrom-Json
    $port = $state.port

    Write-Host "AI Platform Health Check" -ForegroundColor Cyan
    Write-Host "========================" -ForegroundColor DarkCyan

    $processCount = (Get-Process -Name "ollama*" -ErrorAction SilentlyContinue | Measure-Object).Count
    $procColor = if ($processCount -eq 2) { "Green" } elseif ($processCount -gt 2) { "Yellow" } else { "Red" }
    Write-Host "  Processes : $processCount (expected: 2 [app + serve])" -ForegroundColor $procColor
    if ($processCount -gt 2) {
        Write-Host "    WARNING: Multiple instances! Run ai-stop then ai-start -Force" -ForegroundColor Yellow
    }

    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(5)
        $resp = $c.GetAsync("http://127.0.0.1:$port/api/tags").Result
        if ($resp.IsSuccessStatusCode) {
            Write-Host "  API       : HEALTHY (port $port)" -ForegroundColor Green
        } else {
            Write-Host "  API       : UNHEALTHY (HTTP $($resp.StatusCode))" -ForegroundColor Red
        }
    } catch {
        Write-Host "  API       : UNREACHABLE (port $port)" -ForegroundColor Red
    }

    $fwRule = Get-NetFirewallRule -DisplayName "AI-Platform-Ollama-Block-$port" -ErrorAction SilentlyContinue
    $fwColor = if ($fwRule) { "Green" } else { "Yellow" }
    Write-Host "  Firewall  : $(if ($fwRule) { 'BLOCKED inbound port $port' } else { 'NO RULE - port $port exposed!' })" -ForegroundColor $fwColor

    $os = Get-CimInstance Win32_OperatingSystem
    $freeMemPct = [math]::Round(($os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)
    $memColor = if ($freeMemPct -ge 20) { "Green" } else { "Red" }
    Write-Host "  RAM       : $freeMemPct% free" -ForegroundColor $memColor

    try {
        $nvidia = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
        if ($nvidia) {
            $vramFreeGB = [math]::Round([double]($nvidia.Trim()) / 1024, 1)
            $vramColor = if ($vramFreeGB -ge 4) { "Green" } else { "Red" }
            Write-Host "  VRAM      : $vramFreeGB GB free" -ForegroundColor $vramColor
        }
    } catch {}

    $envSet = ($env:OLLAMA_HOST -eq "127.0.0.1:$port") -and ($env:OPENAI_BASE_URL -eq "http://127.0.0.1:$port/v1")
    Write-Host "  Env vars  : $(if ($envSet) { 'OK' } else { 'NOT SET - re-source profile-helpers.ps1' })" -ForegroundColor $(if ($envSet) { "Green" } else { "Yellow" })
}

# Helper summary printed at end of source – omitted to avoid parsing issues in this context
# Write-Host "  ai-start         Start Ollama and local AI platform (single-instance)" -ForegroundColor Gray
# Write-Host "  ai-stop          Shut down platform (kills all Ollama, cleans state)" -ForegroundColor Gray
# Write-Host "  ai-port          Check Ollama status" -ForegroundColor Gray
# Write-Host "  ai-health        Full health check (processes, API, firewall, resources)" -ForegroundColor Gray
# Write-Host "  ai-provider      Show active provider/model" -ForegroundColor Gray
# Write-Host "  ai-switch        Switch model mid-session (ai-switch <model>)" -ForegroundColor Gray
# Write-Host "  ai-code          Launch aider for coding" -ForegroundColor Gray
# Write-Host "  ai-hermes-start  Launch containerized Hermes agent" -ForegroundColor Gray
# Write-Host "  ai-hermes-stop   Stop Hermes and extract output files" -ForegroundColor Gray
# Write-Host "  ai-audit-last    Show recent audit log entries" -ForegroundColor Gray
# Write-Host "  ai-policy        Show provider policy" -ForegroundColor Gray
# Write-Host "  ai-models        List configured models" -ForegroundColor Gray
Write-Host "  ai-auth          Show auth status" -ForegroundColor Gray
Write-Host "  ai-auth-set      Store API key for cloud provider" -ForegroundColor Gray
Write-Host "  ai-cache         Show/clear prompt cache" -ForegroundColor Gray
Write-Host "  ai-config        Show full platform configuration" -ForegroundColor Gray
Write-Host ""
Write-Host "  ollama serve     BLOCKED — use ai-start instead" -ForegroundColor DarkGray
Write-Host "  ollama <other>   Passed through to ollama.exe normally" -ForegroundColor DarkGray