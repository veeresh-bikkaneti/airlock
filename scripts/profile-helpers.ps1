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
            if ($c.GetAsync("http://127.0.0.1:$($data.port)/v1/models").Result.IsSuccessStatusCode) {
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

    # Background model pulls/imports (ModelPull-*, HFImport-*) are Start-Job jobs in this session —
    # surface their state so "is it hung?" has an answer without grepping the JSONL log.
    $pullJobs = Get-Job | Where-Object { $_.Name -like "ModelPull-*" -or $_.Name -like "HFImport-*" }
    if ($pullJobs) {
        Write-Host ""
        Write-Host "Background pulls:" -ForegroundColor Cyan
        foreach ($j in $pullJobs) {
            $color = switch ($j.State) { 'Running' { 'Yellow' }; 'Completed' { 'Green' }; 'Failed' { 'Red' }; default { 'Gray' } }
            Write-Host "  $($j.Name): $($j.State)" -ForegroundColor $color
        }
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
    param([string]$Model)

    $file = "$env:USERPROFILE\.ai-platform\state\active-provider.json"
    if (-not (Test-Path $file)) {
        Write-Host "No active session. Run ai-start first." -ForegroundColor Red
        return
    }
    $data = Get-Content $file -Raw | ConvertFrom-Json
    $targetModel = if ($Model) { $Model } else { $data.model }

    try {
        $installed = & ollama list 2>$null
    } catch {
        Write-Host "Cannot run 'ollama list' — is Ollama installed and on PATH?" -ForegroundColor Red
        return
    }
    if (-not ($installed -match [regex]::Escape($targetModel))) {
        Write-Host "Model '$targetModel' not found in 'ollama list'." -ForegroundColor Red
        Write-Host "Available models:" -ForegroundColor Gray
        $installed | Select-Object -Skip 1 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        return
    }

    # $data.endpoint may be the raw Ollama endpoint, or — if ai-memory-on is active — the
    # memory-service RAG proxy, which only implements /health, /v1/chat/completions, and
    # /v1/memory/*, not /v1/models. Probe whichever route the target actually has.
    $memPortFile = "$env:USERPROFILE\.ai-platform\.memory-port.json"
    $isMemoryProxy = $false
    if (Test-Path $memPortFile) {
        $memPort = (Get-Content $memPortFile -Raw | ConvertFrom-Json).port
        $isMemoryProxy = ([uri]$data.endpoint).Port -eq $memPort
    }
    $probeUrl = if ($isMemoryProxy) { ($data.endpoint -replace '/v1/?$', '') + "/health" } else { $data.endpoint.TrimEnd('/') + "/models" }
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(5)
        $ok = $c.GetAsync($probeUrl).Result.IsSuccessStatusCode
    } catch { $ok = $false }
    if (-not $ok) {
        Write-Host "Endpoint $($data.endpoint) is not responding. Run ai-start or ai-health first." -ForegroundColor Red
        return
    }

    # --openai-api-base is not enough on its own: LiteLLM (what aider uses under the hood)
    # silently prefers OPENAI_API_BASE/OPENAI_BASE_URL env vars over CLI flags whenever
    # they're already set to something else - documented the hard way in this repo's own
    # docs/08-Agent-CLI-Setup-Guide.md. Force them to match so the flag can't lose.
    $env:OPENAI_API_BASE = $data.endpoint
    $env:OPENAI_BASE_URL = $data.endpoint
    $env:OPENAI_API_KEY  = "ollama"

    Write-Host "Launching aider — model: $targetModel  endpoint: $($data.endpoint)" -ForegroundColor Green
    aider --model "openai/$targetModel" --openai-api-base $data.endpoint --openai-api-key "ollama"
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

# Start the opt-in memory-service (vector DB + RAG + short/long-term memory).
function global:ai-memory-start {
    & "$env:USERPROFILE\.ai-platform\scripts\Start-MemoryService.ps1" @args
}

# Stop the memory-service.
function global:ai-memory-stop {
    & "$env:USERPROFILE\.ai-platform\scripts\Stop-MemoryService.ps1" @args
}

# Show memory-service health (process, API, firewall).
function global:ai-memory-status {
    $file = "$env:USERPROFILE\.ai-platform\.memory-port.json"
    if (-not (Test-Path $file)) {
        Write-Host "memory-service not running. Run ai-memory-start first." -ForegroundColor Yellow
        return
    }
    $state = Get-Content $file -Raw | ConvertFrom-Json

    Write-Host "Memory Service Status" -ForegroundColor Cyan
    Write-Host "======================" -ForegroundColor DarkCyan

    $proc = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
    Write-Host "  Process   : $(if ($proc) { "RUNNING (PID $($state.pid))" } else { "NOT RUNNING (stale state)" })" -ForegroundColor $(if ($proc) { "Green" } else { "Red" })

    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(5)
        $resp = $c.GetAsync("http://127.0.0.1:$($state.port)/health").Result
        Write-Host "  API       : $(if ($resp.IsSuccessStatusCode) { "HEALTHY (port $($state.port))" } else { "UNHEALTHY (HTTP $($resp.StatusCode))" })" -ForegroundColor $(if ($resp.IsSuccessStatusCode) { "Green" } else { "Red" })
    } catch {
        Write-Host "  API       : UNREACHABLE (port $($state.port))" -ForegroundColor Red
    }

    $fwRule = Get-NetFirewallRule -DisplayName "AI-Platform-Memory-Block-$($state.port)" -ErrorAction SilentlyContinue
    Write-Host "  Firewall  : $(if ($fwRule) { "BLOCKED inbound port $($state.port)" } else { "NO RULE on port $($state.port) (defense-in-depth only — listener is loopback-only, not externally reachable either way)" })" -ForegroundColor $(if ($fwRule) { "Green" } else { "Yellow" })

    $providerFile = "$env:USERPROFILE\.ai-platform\state\active-provider.json"
    $routedThroughMemory = $false
    if (Test-Path $providerFile) {
        $providerState = Get-Content $providerFile -Raw | ConvertFrom-Json
        $routedThroughMemory = $providerState.endpoint -like "*:$($state.port)/*"
    }
    Write-Host "  Routing   : $(if ($routedThroughMemory) { "ACTIVE - clients proxied through memory-service" } else { "INACTIVE - run ai-memory-on to route clients through it" })" -ForegroundColor $(if ($routedThroughMemory) { "Green" } else { "Gray" })
}

# Route the active provider's clients through memory-service (RAG + short/long-term memory).
function global:ai-memory-on {
    $memFile = "$env:USERPROFILE\.ai-platform\.memory-port.json"
    if (-not (Test-Path $memFile)) {
        Write-Host "memory-service not running. Run ai-memory-start first." -ForegroundColor Red
        return
    }
    $providerFile = "$env:USERPROFILE\.ai-platform\state\active-provider.json"
    if (-not (Test-Path $providerFile)) {
        Write-Host "No active session. Run ai-start first." -ForegroundColor Red
        return
    }
    $memState = Get-Content $memFile -Raw | ConvertFrom-Json
    $providerState = Get-Content $providerFile -Raw | ConvertFrom-Json
    $providerState | Add-Member -NotePropertyName "directEndpoint" -NotePropertyValue $providerState.endpoint -Force
    $providerState.endpoint = "http://127.0.0.1:$($memState.port)/v1"
    $providerState.reason = "Routed through memory-service for RAG + short/long-term memory"
    $providerState | ConvertTo-Json | Set-Content $providerFile -Encoding utf8NoBOM

    $env:OPENAI_BASE_URL = $providerState.endpoint
    Write-Host "Memory ON — clients now route through memory-service at $($providerState.endpoint)" -ForegroundColor Green
}

# Revert the active provider's clients back to talking directly to the local backend.
function global:ai-memory-off {
    $providerFile = "$env:USERPROFILE\.ai-platform\state\active-provider.json"
    if (-not (Test-Path $providerFile)) {
        Write-Host "No active session." -ForegroundColor Red
        return
    }
    $providerState = Get-Content $providerFile -Raw | ConvertFrom-Json
    if (-not $providerState.directEndpoint) {
        Write-Host "Memory routing was not active." -ForegroundColor Gray
        return
    }
    $providerState.endpoint = $providerState.directEndpoint
    $providerState.reason = "Memory routing disabled — direct to local backend"
    $providerState.PSObject.Properties.Remove("directEndpoint")
    $providerState | ConvertTo-Json | Set-Content $providerFile -Encoding utf8NoBOM

    $env:OPENAI_BASE_URL = $providerState.endpoint
    Write-Host "Memory OFF — clients back to direct endpoint $($providerState.endpoint)" -ForegroundColor Green
}

# Point Claude Code at the local platform for THIS shell session only — never persisted to
# settings.json or User/Machine env scope. Fixes the failure mode where a permanent
# ANTHROPIC_BASE_URL redirect outlives the platform and breaks Claude Code entirely (see ai-doctor).
function global:ai-claude-on {
    $file = "$env:USERPROFILE\.ai-platform\state\active-provider.json"
    if (-not (Test-Path $file)) {
        Write-Host "No active session. Run ai-start first." -ForegroundColor Red
        return
    }
    $data = Get-Content $file -Raw | ConvertFrom-Json
    # This feature has only ever been tested against Ollama's /v1/messages route - vLLM's
    # OpenAI-compatible server has no documented Messages-API support anywhere in this repo.
    if ($data.provider -ne 'ollama') {
        Write-Host "Active backend is '$($data.provider)', not Ollama - ai-claude-on doesn't know if it speaks the Messages API Claude Code needs." -ForegroundColor Red
        Write-Host "Switch to Ollama first (ai-start -Backend ollama), or use the settings.json env block manually at your own risk." -ForegroundColor Gray
        return
    }
    # Claude Code needs Ollama's /v1/messages route directly - the memory-service RAG proxy
    # doesn't implement it, so always use the real Ollama endpoint, never a memory-routed one.
    $realEndpoint = if ($data.directEndpoint) { $data.directEndpoint } else { $data.endpoint }
    $port = ([uri]$realEndpoint).Port

    $check = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue
    if (-not $check.TcpTestSucceeded) {
        Write-Host "Nothing listening on 127.0.0.1:$port — run ai-start first." -ForegroundColor Red
        return
    }

    # Stash whatever was there before ai-claude-on's first call this shell, so ai-claude-off
    # can restore it instead of just deleting it (a real ANTHROPIC_API_KEY may already be set).
    if (-not $env:AI_CLAUDE_ON_ACTIVE) {
        $env:AI_CLAUDE_PREV_BASE_URL = $env:ANTHROPIC_BASE_URL
        $env:AI_CLAUDE_PREV_API_KEY  = $env:ANTHROPIC_API_KEY
        $env:AI_CLAUDE_ON_ACTIVE     = "1"
    }

    $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$port"
    $env:ANTHROPIC_API_KEY  = "ollama"
    Write-Host "Claude Code ON — this shell now points at the local platform (http://127.0.0.1:$port)." -ForegroundColor Green
    Write-Host "Session-scoped only. Run ai-claude-off (or just close this shell) before using cloud Claude Code again." -ForegroundColor Gray
}

# Undo ai-claude-on: restore whatever ANTHROPIC_BASE_URL/ANTHROPIC_API_KEY this shell had
# before (a real cloud key, or nothing) instead of unconditionally deleting them.
function global:ai-claude-off {
    if ($env:AI_CLAUDE_ON_ACTIVE) {
        if ($env:AI_CLAUDE_PREV_BASE_URL) { $env:ANTHROPIC_BASE_URL = $env:AI_CLAUDE_PREV_BASE_URL } else { Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue }
        if ($env:AI_CLAUDE_PREV_API_KEY) { $env:ANTHROPIC_API_KEY = $env:AI_CLAUDE_PREV_API_KEY } else { Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue }
        Remove-Item Env:\AI_CLAUDE_PREV_BASE_URL, Env:\AI_CLAUDE_PREV_API_KEY, Env:\AI_CLAUDE_ON_ACTIVE -ErrorAction SilentlyContinue
        if ($env:ANTHROPIC_API_KEY) {
            Write-Host "Claude Code OFF — restored this shell's previous Anthropic settings." -ForegroundColor Green
        } else {
            Write-Host "Claude Code OFF — this shell talks to the real Anthropic API again (no key was set before ai-claude-on, so Claude Code may prompt you to log in)." -ForegroundColor Green
        }
    } else {
        Remove-Item Env:\ANTHROPIC_BASE_URL, Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
        Write-Host "Claude Code OFF — this shell talks to the real Anthropic API again." -ForegroundColor Green
    }
}

# Diagnose stale AI-tool endpoint variables — at any scope — that point at a local port with
# nothing listening. Covers the ANTHROPIC_BASE_URL incident: a redirect that outlived the
# platform it pointed at, surfacing as a misleading "firewall or proxy" error in the actual tool.
function global:ai-doctor {
    Write-Host "AI Platform Doctor" -ForegroundColor Cyan
    Write-Host "===================" -ForegroundColor DarkCyan

    $checks = @(
        @{ Name = 'ANTHROPIC_BASE_URL';             KeyVar = 'ANTHROPIC_API_KEY' }
        @{ Name = 'OPENAI_BASE_URL';                KeyVar = 'OPENAI_API_KEY' }
        @{ Name = 'OPENAI_API_BASE';                KeyVar = 'OPENAI_API_KEY' }
        @{ Name = 'COPILOT_PROVIDER_BASE_URL';       KeyVar = $null }
        @{ Name = 'GROK_MODEL_GROK_BUILD_BASE_URL';  KeyVar = $null }
        @{ Name = 'GROK_CLI_CHAT_PROXY_BASE_URL';    KeyVar = $null }
    )
    $scopes = @('Process', 'User', 'Machine')
    $issues = 0

    foreach ($check in $checks) {
        foreach ($scope in $scopes) {
            $value = [Environment]::GetEnvironmentVariable($check.Name, $scope)
            if (-not $value) { continue }
            try { $uri = [uri]$value } catch { continue }
            if ($uri.Host -notin @('127.0.0.1', 'localhost')) { continue }

            $alive = (Test-NetConnection -ComputerName $uri.Host -Port $uri.Port -WarningAction SilentlyContinue).TcpTestSucceeded
            if (-not $alive) {
                $issues++
                Write-Host ""
                Write-Host "  DEAD REDIRECT: $($check.Name) [$scope scope] = $value" -ForegroundColor Red
                Write-Host "    Nothing listening on $($uri.Host):$($uri.Port)." -ForegroundColor Yellow
                if ($scope -eq 'Process') {
                    $clearCmd = "Remove-Item Env:\$($check.Name)" + $(if ($check.KeyVar) { ", Env:\$($check.KeyVar)" } else { "" }) + " -ErrorAction SilentlyContinue"
                    Write-Host "    Fix (this shell): $clearCmd" -ForegroundColor Gray
                } else {
                    Write-Host "    Fix ($scope scope, persists across shells): [Environment]::SetEnvironmentVariable('$($check.Name)', `$null, '$scope')" -ForegroundColor Gray
                }
            }
        }
    }

    $settingsPaths = @("$env:USERPROFILE\.claude\settings.json", "$env:USERPROFILE\.claude\settings.local.json")
    # These two are relative to the current directory - only found if run from inside a
    # project checkout. Said explicitly below so "no dead redirects" can't be misread as
    # "checked every project", when a project-local file just wasn't reachable from here.
    $projectRel = @(".claude\settings.json", ".claude\settings.local.json")
    $projectFound = 0
    foreach ($rel in $projectRel) {
        if (Test-Path $rel) { $settingsPaths += (Resolve-Path $rel).Path; $projectFound++ }
    }
    foreach ($path in ($settingsPaths | Select-Object -Unique)) {
        if (-not (Test-Path $path)) { continue }
        try {
            $json = Get-Content $path -Raw | ConvertFrom-Json
            $baseUrl = $json.env.ANTHROPIC_BASE_URL
            if ($baseUrl) {
                $uri = [uri]$baseUrl
                $alive = (Test-NetConnection -ComputerName $uri.Host -Port $uri.Port -WarningAction SilentlyContinue).TcpTestSucceeded
                if (-not $alive) {
                    $issues++
                    Write-Host ""
                    Write-Host "  DEAD REDIRECT: $path -> env.ANTHROPIC_BASE_URL = $baseUrl" -ForegroundColor Red
                    Write-Host "    Nothing listening on $($uri.Host):$($uri.Port). This disables cloud Claude Code entirely while it's set." -ForegroundColor Yellow
                    Write-Host "    Fix: remove the 'env' block from $path, or switch to ai-claude-on / ai-claude-off (session-scoped, not permanent)." -ForegroundColor Gray
                }
            }
        } catch {}
    }

    Write-Host ""
    if ($issues -eq 0) {
        Write-Host "  No dead redirects found in User/Machine/process env vars or $env:USERPROFILE\.claude\settings*.json." -ForegroundColor Green
        if ($projectFound -eq 0) {
            Write-Host "  Not checked: this directory's own .claude\settings*.json - $(Get-Location) doesn't have one, or you're not in a project root. cd there and re-run if you expect one." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  $issues dead redirect(s) found. After clearing, restart every open shell and every running agent CLI — they hold stale copies of the environment." -ForegroundColor Yellow
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
    Write-Host "  Firewall  : $(if ($fwRule) { "BLOCKED inbound port $port" } else { "NO RULE - port $port exposed!" })" -ForegroundColor $fwColor

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
# Write-Host "  ai-start         Start Ollama and Airlock (single-instance)" -ForegroundColor Gray
# Write-Host "  ai-stop          Shut down platform (kills all Ollama, cleans state)" -ForegroundColor Gray
# Write-Host "  ai-port          Check Ollama status" -ForegroundColor Gray
# Write-Host "  ai-health        Full health check (processes, API, firewall, resources)" -ForegroundColor Gray
# Write-Host "  ai-doctor        Diagnose dead ANTHROPIC_*/OPENAI_*/COPILOT_*/GROK_* redirects" -ForegroundColor Gray
# Write-Host "  ai-claude-on     Point Claude Code at the local platform (this shell only)" -ForegroundColor Gray
# Write-Host "  ai-claude-off    Undo ai-claude-on" -ForegroundColor Gray
# Write-Host "  ai-provider      Show active provider/model" -ForegroundColor Gray
# Write-Host "  ai-switch        Switch model mid-session (ai-switch <model>)" -ForegroundColor Gray
# Write-Host "  ai-code          Launch aider for coding" -ForegroundColor Gray
# Write-Host "  ai-hermes-start  Launch containerized Hermes agent" -ForegroundColor Gray
# Write-Host "  ai-hermes-stop   Stop Hermes and extract output files" -ForegroundColor Gray
# Write-Host "  ai-audit-last    Show recent audit log entries" -ForegroundColor Gray
# Write-Host "  ai-policy        Show provider policy" -ForegroundColor Gray
# Write-Host "  ai-models        List configured models" -ForegroundColor Gray
# Write-Host "  ai-auth          Show auth status" -ForegroundColor Gray
# Write-Host "  ai-auth-set      Store API key for cloud provider" -ForegroundColor Gray
# Write-Host "  ai-cache         Show/clear prompt cache" -ForegroundColor Gray
# Write-Host "  ai-config        Show full platform configuration" -ForegroundColor Gray
# Write-Host ""
# Write-Host "  ollama serve     BLOCKED — use ai-start instead" -ForegroundColor DarkGray
# Write-Host "  ollama <other>   Passed through to ollama.exe normally" -ForegroundColor DarkGray