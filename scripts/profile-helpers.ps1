# profile-helpers.ps1 — Add these to your PowerShell profile
# Source this file or copy its contents into your $PROFILE
# Usage: . "$env:USERPROFILE\.ai-platform\scripts\profile-helpers.ps1"

$Script:PlatformDir = "$env:USERPROFILE\.ai-platform"

# ADR-006 task router - pure cascade lives in its own file so it stays unit-testable
# (Test-TaskRoute.ps1) without dragging in this file's env/file I/O.
. (Join-Path $PSScriptRoot "Get-TaskRoute.ps1")
. (Join-Path $PSScriptRoot "agent-state-helpers.ps1")

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

# AIR-016 coding door. Default profile is Unsloth llama-server; explicit
# -Profile is required for any other catalogue entry (Start-AgentSession
# still never auto-selects). Chat stays on ai-start.
function global:ai-agent-start {
    param(
        [string]$Profile = 'llamacpp-qwen38-ud-q3-k-xl',
        [switch]$WhatIf,
        [switch]$ForceVerify,
        [switch]$NoCache,
        [switch]$DownloadConfirmed
    )
    $session = Join-Path $PSScriptRoot "Start-AgentSession.ps1"
    if (-not (Test-Path $session)) {
        $session = "$env:USERPROFILE\.ai-platform\scripts\Start-AgentSession.ps1"
    }
    & $session -Profile $Profile -Harness 'pi-worker' -WhatIf:$WhatIf -ForceVerify:$ForceVerify -NoCache:$NoCache -DownloadConfirmed:$DownloadConfirmed
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
        $progressFile = "$env:USERPROFILE\.ai-platform\.pull-progress.json"
        $progress = if (Test-Path $progressFile) { Get-Content $progressFile -Raw | ConvertFrom-Json } else { $null }
        foreach ($j in $pullJobs) {
            $color = switch ($j.State) { 'Running' { 'Yellow' }; 'Completed' { 'Green' }; 'Failed' { 'Red' }; default { 'Gray' } }
            if ($j.State -eq 'Running' -and $progress -and $j.Name -eq "ModelPull-$($progress.model)") {
                $speedPart = if ($progress.speed) { " at $($progress.speed)" } else { "" }
                $etaPart = if ($progress.eta) { ", ~$($progress.eta) left" } else { "" }
                Write-Host "  $($j.Name): $($progress.percent)% ($($progress.downloaded)/$($progress.total))$speedPart$etaPart" -ForegroundColor $color
            } else {
                Write-Host "  $($j.Name): $($j.State)" -ForegroundColor $color
            }
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
            Clear-AirlockActiveAgentCertificate -CertificatePath "$env:USERPROFILE\.ai-platform\state\active-agent.json" | Out-Null
            Write-Host "Invalidated coding certificate (ai-agent-start required before the next agentic session)." -ForegroundColor Yellow
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

# Launch aider against a proven coding certificate (AIR-016 D1). Chat
# provider state from ai-start is not enough.
function global:ai-code {
    param([string]$Model)

    $certPath = "$env:USERPROFILE\.ai-platform\state\active-agent.json"
    $certificate = $null
    if (Test-Path $certPath) {
        try { $certificate = Get-Content $certPath -Raw | ConvertFrom-Json } catch { $certificate = $null }
    }
    $compatible = if ($certificate -and $certificate.harness) { @([string]$certificate.harness) } else { @('pi-worker') }
    $validity = Resolve-AirlockCertificateValidity -Certificate $certificate -Now ([DateTime]::UtcNow) -CompatibleHarnesses $compatible
    if (-not $validity.Valid) {
        Write-Host "No valid coding certificate ($($validity.Reason)). Run ai-agent-start first." -ForegroundColor Red
        Write-Host "  $($validity.Detail)" -ForegroundColor Yellow
        return
    }

    $targetModel = if ($Model) { $Model } else { $certificate.model }
    $endpoint = $certificate.transport.endpoint
    if (-not $endpoint) {
        Write-Host "Certificate is missing transport.endpoint. Run ai-agent-start again." -ForegroundColor Red
        return
    }

    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(5)
        $ok = $c.GetAsync($endpoint.TrimEnd('/') + "/models").Result.IsSuccessStatusCode
    } catch { $ok = $false }
    if (-not $ok) {
        Write-Host "Certified endpoint $endpoint is not responding. Run ai-agent-start." -ForegroundColor Red
        return
    }

    $env:OPENAI_API_BASE = $endpoint
    $env:OPENAI_BASE_URL = $endpoint
    $env:OPENAI_API_KEY  = "ollama"

    Write-Host "Launching aider — model: $targetModel  endpoint: $endpoint (from active-agent.json)" -ForegroundColor Green
    aider --model "openai/$targetModel" --openai-api-base $endpoint --openai-api-key "ollama"
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

# Shared I/O glue behind ai-route and ai-handoff: reads the active model's
# supportsFunctionCalling flag, the ADR-006 keyword config, and any given files' line
# counts, then hands them to the pure Get-TaskRoute cascade. Kept as one function so
# ai-route's "should I go local right now" and ai-handoff's handoff note can never
# silently disagree - that's the whole point of sharing one rule set (ADR-006 consequences).
function Resolve-CurrentTaskRoute {
    param(
        [Parameter(Mandatory)][string]$Description,
        [string[]]$Files = @()
    )

    $providerFile = "$Script:PlatformDir\state\active-provider.json"
    $modelsFile   = "$Script:PlatformDir\config\models.json"
    if (-not (Test-Path $providerFile)) {
        return [pscustomobject]@{ Error = "No active session. Run ai-start first."; Route = $null; ActiveModel = $null }
    }
    if (-not (Test-Path $modelsFile)) {
        return [pscustomobject]@{ Error = "No model registry found at $modelsFile."; Route = $null; ActiveModel = $null }
    }

    $activeModel = (Get-Content $providerFile -Raw | ConvertFrom-Json).model
    $modelsConfig = Get-Content $modelsFile -Raw | ConvertFrom-Json
    $modelInfo = $modelsConfig.localModels.$activeModel
    if (-not $modelInfo) {
        return [pscustomobject]@{ Error = "Active model '$activeModel' has no entry in models.json - cannot read supportsFunctionCalling."; Route = $null; ActiveModel = $activeModel }
    }

    # ponytail: task-router-keywords.json isn't in setup.ps1's deploy copy list yet (only
    # models.json/policies/*.json/*.template are) - resolve next to this script instead of
    # under $Script:PlatformDir\config, so it works from a repo checkout today. Upgrade path:
    # add it to setup.ps1's config copy step once that file is touched for another reason.
    $keywordsFile = Join-Path $PSScriptRoot "..\config\task-router-keywords.json"
    $keywords = if (Test-Path $keywordsFile) { @((Get-Content $keywordsFile -Raw | ConvertFrom-Json).planningKeywords) } else { @() }

    $fileCount = $Files.Count
    $maxLineCount = 0
    foreach ($f in $Files) {
        if (Test-Path $f) {
            $lineCount = (Get-Content $f -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
            if ($lineCount -gt $maxLineCount) { $maxLineCount = $lineCount }
        }
    }

    $route = Get-TaskRoute -SupportsFunctionCalling ([bool]$modelInfo.supportsFunctionCalling) -Description $Description -Keywords $keywords -FileCount $fileCount -MaxLineCount $maxLineCount
    return [pscustomobject]@{ Error = $null; Route = $route; ActiveModel = $activeModel }
}

# ADR-006 advisory task router. Prints the decision and reason and stops - never launches
# ai-claude-on, aider, or anything else. Auto-routing (deciding AND switching) is a
# deliberate non-goal for this pass (see ADR-006's Alternatives considered); the user still
# acts on this manually.
function global:ai-route {
    param(
        [Parameter(Position = 0, Mandatory)][string]$Description,
        # The router can't infer touched files from free-text alone - pass them explicitly
        # when known, so rule 3 (file count / line count) has real signal instead of always
        # defaulting to "0 files, 0 lines".
        [string[]]$Files = @()
    )

    $result = Resolve-CurrentTaskRoute -Description $Description -Files $Files
    if ($result.Error) {
        Write-Host $result.Error -ForegroundColor Red
        return
    }

    $color = if ($result.Route.Decision -eq 'local') { 'Green' } else { 'Yellow' }
    Write-Host "Route : $($result.Route.Decision.ToUpper())" -ForegroundColor $color
    Write-Host "Reason: $($result.Route.Reason)" -ForegroundColor Gray
    Write-Host "(advisory only - does not launch ai-claude-on, aider, or anything else)" -ForegroundColor DarkGray
}

# AIR-16 handoff policy. Appends the current task's ADR-006 route decision below the
# ADR-004 canonical block in .ai-context\SESSION_STATE.md - never rewrites or reorders the
# canonical fields, which stay owned by the external ai-context-sync.py hook.
function global:ai-handoff {
    param(
        [Parameter(Position = 0, Mandatory)][string]$Description,
        [string[]]$Files = @()
    )

    $stateFile = Join-Path (Get-Location).Path ".ai-context\SESSION_STATE.md"
    if (-not (Test-Path $stateFile)) {
        Write-Host "No .ai-context\SESSION_STATE.md in $(Get-Location) - nothing to append to." -ForegroundColor Red
        Write-Host "That file is written by Claude Code's ai-context-sync.py hook (ADR-004, Stop/SessionEnd/PreCompact) - trigger one Claude Code turn in this repo first." -ForegroundColor Gray
        return
    }

    $result = Resolve-CurrentTaskRoute -Description $Description -Files $Files
    if ($result.Error) {
        Write-Host $result.Error -ForegroundColor Red
        return
    }

    $appendLines = @(
        ""
        "## Task route (ADR-006, appended by ai-handoff)"
        "- decided_at: $([DateTime]::UtcNow.ToString('o'))"
        "- description: $Description"
        "- route: $($result.Route.Decision)"
        "- reason: $($result.Route.Reason)"
    )
    Add-Content -Path $stateFile -Value $appendLines -Encoding utf8
    Write-Host "Appended route decision ($($result.Route.Decision)) to $stateFile" -ForegroundColor Green
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

# Start the opt-in tool-call proxy (fixes unreliable Ollama tool-calling for
# harnesses like opencode - see opencode.json.template).
function global:ai-tool-proxy-start {
    & "$env:USERPROFILE\.ai-platform\scripts\Start-ToolProxy.ps1" @args
}

# Stop the tool-call proxy.
function global:ai-tool-proxy-stop {
    & "$env:USERPROFILE\.ai-platform\scripts\Stop-ToolProxy.ps1" @args
}

# Show tool-proxy health (process, API, firewall).
function global:ai-tool-proxy-status {
    $file = "$env:USERPROFILE\.ai-platform\.tool-proxy-port.json"
    if (-not (Test-Path $file)) {
        Write-Host "tool-proxy not running. Run ai-tool-proxy-start first." -ForegroundColor Yellow
        return
    }
    $state = Get-Content $file -Raw | ConvertFrom-Json

    Write-Host "Tool-Call Proxy Status" -ForegroundColor Cyan
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

    $fwRule = Get-NetFirewallRule -DisplayName "AI-Platform-ToolProxy-Block-$($state.port)" -ErrorAction SilentlyContinue
    Write-Host "  Firewall  : $(if ($fwRule) { "BLOCKED inbound port $($state.port)" } else { "NO RULE on port $($state.port) (defense-in-depth only - listener is loopback-only, not externally reachable either way)" })" -ForegroundColor $(if ($fwRule) { "Green" } else { "Yellow" })
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

        # ADR-007 point 2: /health now carries index freshness alongside the
        # liveness check, so this reuses the same round-trip instead of a
        # second request.
        if ($resp.IsSuccessStatusCode) {
            $healthBody = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
            $freshness = $healthBody.memoryFreshness
            if ($freshness -and $freshness.indexed) {
                $behindText = if ($null -ne $freshness.commitsBehind) { "$($freshness.commitsBehind) commits behind" } else { "commits-behind unknown (git unavailable)" }
                $hoursText = if ($null -ne $freshness.hoursSinceIndex) { "{0:N1}h since index" -f $freshness.hoursSinceIndex } else { "age unknown" }
                $staleColor = if ($freshness.commitsBehind -gt 0) { "Yellow" } else { "Green" }
                Write-Host "  Index     : $behindText, $hoursText" -ForegroundColor $staleColor
            } elseif ($freshness) {
                Write-Host "  Index     : NOT YET INDEXED (no memories stored)" -ForegroundColor Gray
            }
        }
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

# Pure decision helpers for the ai-claude-on/off stash-and-restore state machine - no file
# I/O, no network, no env var access - so they're directly testable (see Test-ClaudeToggle.ps1),
# same reason Get-ModelSizingCeilingGB was extracted out of Start-AI.ps1.
function Resolve-ClaudeOnStash {
    param(
        [string]$CurrentBaseUrl,
        [string]$CurrentApiKey,
        [bool]$AlreadyActive
    )
    if ($AlreadyActive) {
        # A second ai-claude-on in the same shell must not re-stash the redirect it just
        # set as if it were the user's original value - that would lose the real one.
        return [pscustomobject]@{ ShouldStash = $false; PrevBaseUrl = $null; PrevApiKey = $null }
    }
    return [pscustomobject]@{ ShouldStash = $true; PrevBaseUrl = $CurrentBaseUrl; PrevApiKey = $CurrentApiKey }
}

function Resolve-ClaudeOffRestore {
    param(
        [bool]$WasActive,
        [string]$PrevBaseUrl,
        [string]$PrevApiKey
    )
    if (-not $WasActive) {
        # ai-claude-off called without a matching ai-claude-on this shell (e.g. leftover
        # habit, or a fresh shell) - nothing was stashed, so just clear.
        return [pscustomobject]@{ Mode = 'PlainClear'; BaseUrl = $null; ApiKey = $null }
    }
    if ($PrevApiKey) {
        return [pscustomobject]@{ Mode = 'Restored'; BaseUrl = $PrevBaseUrl; ApiKey = $PrevApiKey }
    }
    # Active, but nothing was set before ai-claude-on ran - correct to clear, but the
    # "restored" claim would be false since there was nothing to restore.
    return [pscustomobject]@{ Mode = 'ClearedNoPriorKey'; BaseUrl = $null; ApiKey = $null }
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
    # can restore it instead of just deleting it (a real ANTHROPIC_AUTH_TOKEN may already be set).
    #
    # AIR-H2: this used to set ANTHROPIC_API_KEY. Per Anthropic's LLM gateway docs
    # (code.claude.com/docs/en/llm-gateway-connect, "Conflicts with an existing login"):
    # "With ANTHROPIC_AUTH_TOKEN, the variable takes precedence immediately. With
    # ANTHROPIC_API_KEY, you are prompted once in interactive mode to approve the key before
    # it takes over." ai-claude-on needs to work without an interactive approval step.
    $stash = Resolve-ClaudeOnStash -CurrentBaseUrl $env:ANTHROPIC_BASE_URL -CurrentApiKey $env:ANTHROPIC_AUTH_TOKEN -AlreadyActive ([bool]$env:AI_CLAUDE_ON_ACTIVE)
    if ($stash.ShouldStash) {
        $env:AI_CLAUDE_PREV_BASE_URL = $stash.PrevBaseUrl
        $env:AI_CLAUDE_PREV_API_KEY  = $stash.PrevApiKey
        $env:AI_CLAUDE_ON_ACTIVE     = "1"
    }

    $env:ANTHROPIC_BASE_URL   = "http://127.0.0.1:$port"
    $env:ANTHROPIC_AUTH_TOKEN = "ollama"
    Write-Host "Claude Code ON — this shell now points at the local platform (http://127.0.0.1:$port)." -ForegroundColor Green
    Write-Host "Session-scoped only. Run ai-claude-off (or just close this shell) before using cloud Claude Code again." -ForegroundColor Gray

    # ADR-006 known gap, closed: log the switch so the handoff note isn't optional
    # and easy to forget under the pressure that caused it (a cloud usage limit).
    ai-handoff "Switched to local via ai-claude-on"
}

# Undo ai-claude-on: restore whatever ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN this shell had
# before (a real cloud token, or nothing) instead of unconditionally deleting them.
function global:ai-claude-off {
    $restore = Resolve-ClaudeOffRestore -WasActive ([bool]$env:AI_CLAUDE_ON_ACTIVE) -PrevBaseUrl $env:AI_CLAUDE_PREV_BASE_URL -PrevApiKey $env:AI_CLAUDE_PREV_API_KEY

    if ($restore.BaseUrl) { $env:ANTHROPIC_BASE_URL = $restore.BaseUrl } else { Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue }
    if ($restore.ApiKey) { $env:ANTHROPIC_AUTH_TOKEN = $restore.ApiKey } else { Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue }
    # AIR-H2: a shell that ran ai-claude-on before this rename may still carry the old
    # ANTHROPIC_API_KEY = "ollama" sentinel this function used to set. Clear only that exact
    # leftover placeholder - never a real user-set ANTHROPIC_API_KEY, which this mechanism
    # has never stashed and has no business touching.
    if ($env:ANTHROPIC_API_KEY -eq 'ollama') { Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue }
    Remove-Item Env:\AI_CLAUDE_PREV_BASE_URL, Env:\AI_CLAUDE_PREV_API_KEY, Env:\AI_CLAUDE_ON_ACTIVE -ErrorAction SilentlyContinue

    switch ($restore.Mode) {
        'Restored'           { Write-Host "Claude Code OFF — restored this shell's previous Anthropic settings." -ForegroundColor Green }
        'ClearedNoPriorKey'  { Write-Host "Claude Code OFF — this shell talks to the real Anthropic API again (no key was set before ai-claude-on, so Claude Code may prompt you to log in)." -ForegroundColor Green }
        default              { Write-Host "Claude Code OFF — this shell talks to the real Anthropic API again." -ForegroundColor Green }
    }
}

# Fast TCP liveness probe. Replaces Test-NetConnection here: that cmdlet runs extra
# diagnostics (ping, route lookup) that make a multi-variable sweep take seconds, and it
# has no short timeout knob. ADR-008 caps a probe at 250 ms.
function script:Test-PortAlive {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 250)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch { return $false } finally { $client.Dispose() }
}

# Walk the process tree from a starting PID up to the session root. Returns an ordered list
# of [pscustomobject]@{ Id; Name }. This is what turns "your environment is wrong" into
# "THIS process is handing it to you", which is the difference between a fix that holds and
# a fix that evaporates when you open the next terminal (ADR-008 D1).
function script:Get-ProcessAncestry {
    param([int]$StartPid = $PID, [int]$MaxDepth = 12)
    $chain = @()
    $id = $StartPid
    for ($i = 0; $i -lt $MaxDepth -and $id; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        $chain += [pscustomobject]@{ Id = $p.ProcessId; Name = $p.Name }
        if ($p.ParentProcessId -eq $p.ProcessId) { break }
        $id = $p.ParentProcessId
    }
    return $chain
}

# Processes that own the login session's environment block. Windows hands each new process a
# COPY of its parent's block at creation — nothing re-reads the registry — so when one of
# these is the carrier, no amount of registry cleaning reaches it. Only ending the session does.
$script:AirlockSessionRoots = @('explorer.exe', 'userinit.exe', 'winlogon.exe', 'sihost.exe')

# Diagnose stale AI-tool endpoint variables — at any scope — that point at a local port with
# nothing listening. Covers the ANTHROPIC_BASE_URL incident: a redirect that outlived the
# platform it pointed at, surfacing as a misleading "firewall or proxy" error in the actual tool.
#
# Three classes of finding, in increasing order of how much they mislead you:
#   1. PERSISTED    — a dead value in User/Machine scope or a settings.json env block. Clear it.
#   2. ORPHANED     — dead at Process scope but CLEAN at User and Machine. The registry is
#                     already fixed; a running ancestor is handing you a frozen copy. Clearing
#                     it in this shell works, and the next shell is broken again.
#   3. SELFHEAL     — a SessionStart hook that re-applies a redirect after you fix it, so every
#                     correct fix appears to regress.
function global:ai-doctor {
    Write-Host "AI Platform Doctor" -ForegroundColor Cyan
    Write-Host "===================" -ForegroundColor DarkCyan

    $checks = @(
        @{ Name = 'ANTHROPIC_BASE_URL';             KeyVar = 'ANTHROPIC_AUTH_TOKEN' }
        @{ Name = 'ANTHROPIC_API_URL';              KeyVar = $null }
        @{ Name = 'OPENAI_BASE_URL';                KeyVar = 'OPENAI_API_KEY' }
        @{ Name = 'OPENAI_API_BASE';                KeyVar = 'OPENAI_API_KEY' }
        @{ Name = 'COPILOT_PROVIDER_BASE_URL';      KeyVar = $null }
        @{ Name = 'GROK_MODEL_GROK_BUILD_BASE_URL'; KeyVar = $null }
        @{ Name = 'GROK_CLI_CHAT_PROXY_BASE_URL';   KeyVar = $null }
    )
    $issues = 0
    $orphans = 0

    # Provenance (ADR-008 D2): ai-claude-on stamps AIRLOCK_INJECTED so a redirect airlock set
    # can be told apart from one some other tool set. The 4-day incident this function exists
    # for was caused by a third-party proxy — naming it as foreign on day one is the whole point.
    $airlockOwned = ($env:AIRLOCK_INJECTED -eq '1')

    foreach ($check in $checks) {
        $values = @{}
        foreach ($scope in @('Process', 'User', 'Machine')) {
            $values[$scope] = [Environment]::GetEnvironmentVariable($check.Name, $scope)
        }
        if (-not ($values.Values | Where-Object { $_ })) { continue }

        foreach ($scope in @('Process', 'User', 'Machine')) {
            $value = $values[$scope]
            if (-not $value) { continue }
            try { $uri = [uri]$value } catch { continue }
            if ($uri.Host -notin @('127.0.0.1', 'localhost', '::1')) { continue }
            # [uri]::Port defaults to 80/443 when the value has no explicit port (verified:
            # [uri]"http://127.0.0.1" -> Port 80). These redirects are always host:port; a
            # bare-host value would silently probe the wrong port and can't be judged reliably.
            if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+:\d+') { continue }
            if (Test-PortAlive -TargetHost $uri.Host -Port $uri.Port) { continue }

            $issues++
            $isOrphan = ($scope -eq 'Process') -and (-not $values['User']) -and (-not $values['Machine'])
            $ownedByUs = $airlockOwned -and ($env:AIRLOCK_ENDPOINT -eq $value)

            Write-Host ""
            if ($isOrphan) {
                $orphans++
                Write-Host "  ORPHANED POINTER: $($check.Name) = $value" -ForegroundColor Red
                Write-Host "    Set in this process, but CLEAN at User and Machine scope, and nothing is listening on $($uri.Host):$($uri.Port)." -ForegroundColor Yellow
                Write-Host "    The saved configuration is already correct. A running ancestor process is handing this shell a frozen copy." -ForegroundColor Yellow
            } else {
                Write-Host "  DEAD REDIRECT: $($check.Name) [$scope scope] = $value" -ForegroundColor Red
                Write-Host "    Nothing listening on $($uri.Host):$($uri.Port)." -ForegroundColor Yellow
            }

            Write-Host "    Set by: $(if ($ownedByUs) { 'airlock (ai-claude-on)' } else { 'NOT airlock — some other tool set this' })" -ForegroundColor $(if ($ownedByUs) { 'Gray' } else { 'Magenta' })

            if ($isOrphan) {
                $chain = Get-ProcessAncestry
                Write-Host "    Carrier chain: $(($chain | ForEach-Object { "$($_.Name)($($_.Id))" }) -join ' <- ')" -ForegroundColor Gray
                $root = $chain | Select-Object -Last 1
                if ($root -and ($root.Name -in $script:AirlockSessionRoots)) {
                    Write-Host "    FIX: SIGN OUT of Windows and sign back in (or reboot)." -ForegroundColor Cyan
                    Write-Host "         The chain tops out at $($root.Name), which owns your login session's environment." -ForegroundColor Gray
                    Write-Host "         Windows gives each process a COPY of the environment at creation and never re-reads the registry," -ForegroundColor Gray
                    Write-Host "         so clearing the registry cannot reach it. Only ending the session rebuilds the block." -ForegroundColor Gray
                    Write-Host "    Temporary (this shell only, gone in the next terminal): Remove-Item Env:\$($check.Name) -ErrorAction SilentlyContinue" -ForegroundColor DarkGray
                } elseif ($root) {
                    Write-Host "    FIX: restart $($root.Name) (PID $($root.Id)) and everything it launched." -ForegroundColor Cyan
                    Write-Host "         That process holds the stale copy; its children inherit it." -ForegroundColor Gray
                }
            } elseif ($scope -eq 'Process') {
                $clearCmd = "Remove-Item Env:\$($check.Name)" + $(if ($check.KeyVar) { ", Env:\$($check.KeyVar)" } else { "" }) + " -ErrorAction SilentlyContinue"
                Write-Host "    FIX (this shell): $clearCmd" -ForegroundColor Cyan
            } else {
                Write-Host "    FIX ($scope scope, persists across shells): [Environment]::SetEnvironmentVariable('$($check.Name)', `$null, '$scope')" -ForegroundColor Cyan
                Write-Host "         Then close every open shell and editor — already-running ones keep the old copy." -ForegroundColor Gray
            }
        }
    }

    # --- settings.json: dead env-block redirects, and hooks that re-apply them ---
    $settingsPaths = @(
        "$env:USERPROFILE\.claude\settings.json",
        "$env:USERPROFILE\.claude\settings.local.json"
    )
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
        } catch {
            Write-Host ""
            Write-Host "  UNPARSEABLE: $path is not valid JSON — Claude Code ignores it silently." -ForegroundColor Red
            $issues++
            continue
        }

        $baseUrl = $json.env.ANTHROPIC_BASE_URL
        if ($baseUrl) {
            try {
                $uri = [uri]$baseUrl
                if (-not (Test-PortAlive -TargetHost $uri.Host -Port $uri.Port)) {
                    $issues++
                    Write-Host ""
                    Write-Host "  DEAD REDIRECT: $path -> env.ANTHROPIC_BASE_URL = $baseUrl" -ForegroundColor Red
                    Write-Host "    Nothing listening on $($uri.Host):$($uri.Port). This disables cloud Claude Code entirely while it's set," -ForegroundColor Yellow
                    Write-Host "    and a settings-file env block OVERRIDES a shell export — so ai-claude-off cannot undo it." -ForegroundColor Yellow
                    Write-Host "    FIX: remove the 'env' block from $path, then use ai-claude-on / ai-claude-off (session-scoped, not permanent)." -ForegroundColor Cyan
                }
            } catch {}
        }

        # SessionStart hooks that re-apply a redirect are why a correct fix can appear to
        # regress: the hook runs on every startup/resume and puts the value back. Report only;
        # third-party hooks are legitimate and this function does not edit anyone's config.
        $hookGroups = $json.hooks.SessionStart
        foreach ($group in $hookGroups) {
            foreach ($hook in $group.hooks) {
                $cmd = $hook.command
                if (-not $cmd) { continue }
                if ($cmd -match 'wrap|selfheal|ANTHROPIC_|OPENAI_|setx|SetEnvironmentVariable|BASE_URL') {
                    $issues++
                    Write-Host ""
                    Write-Host "  SESSION HOOK MUTATES ENVIRONMENT: $path" -ForegroundColor Red
                    Write-Host "    matcher: $($group.matcher)" -ForegroundColor Yellow
                    Write-Host "    command: $cmd" -ForegroundColor Yellow
                    Write-Host "    A hook like this runs on every session start/resume. If it re-applies an endpoint variable," -ForegroundColor Yellow
                    Write-Host "    every fix you make will appear to work and then come back. Review it before chasing anything else." -ForegroundColor Yellow
                    Write-Host "    FIX: if you don't recognise this, remove the hook (back the file up first), then re-run ai-doctor." -ForegroundColor Cyan
                }
            }
        }
    }

    # --- source/install skew (AIR-H13): setup.ps1 already overwrites scripts\ from source
    # on every run, so skew here means install.ps1 just hasn't been re-run since a patch
    # landed - not a broken sync mechanism. Only checkable when the standard installer's
    # clone exists; a dev working from an arbitrary repo checkout has no fixed comparison
    # point, so this is skipped rather than guessed - same honesty pattern as $projectFound above.
    $srcScripts = "$env:USERPROFILE\.airlock-src\scripts"
    if (Test-Path $srcScripts) {
        # Compare content with line endings normalized: a fresh `git clone` applies the
        # checkout's core.autocrlf conversion, so byte-identical source can still hash
        # differently than an existing working tree purely from CRLF vs LF - a false skew,
        # not a real one. Normalize before hashing so only actual content differences count.
        function Get-NormalizedContentHash($path) {
            $content = (Get-Content $path -Raw -ErrorAction SilentlyContinue) -replace "`r`n", "`n"
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            try { [BitConverter]::ToString($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($content))) }
            finally { $sha256.Dispose() }
        }
        $skewed = @()
        foreach ($f in Get-ChildItem "$srcScripts\*.ps1") {
            $installedPath = "$env:USERPROFILE\.ai-platform\scripts\$($f.Name)"
            if (-not (Test-Path $installedPath)) { $skewed += $f.Name; continue }
            if ((Get-NormalizedContentHash $f.FullName) -ne (Get-NormalizedContentHash $installedPath)) {
                $skewed += $f.Name
            }
        }
        if ($skewed.Count -gt 0) {
            $issues++
            Write-Host ""
            Write-Host "  INSTALL DRIFT: $($skewed.Count) script(s) differ between ~\.airlock-src (source) and ~\.ai-platform (installed)." -ForegroundColor Red
            Write-Host "    $($skewed -join ', ')" -ForegroundColor Yellow
            Write-Host "    setup.ps1 always overwrites scripts\ from source on every run - this just means it hasn't been re-run since a patch landed there." -ForegroundColor Yellow
            Write-Host "    FIX: cd ~\.airlock-src; git pull --ff-only; .\install.ps1   (or re-run the irm|iex one-liner)" -ForegroundColor Cyan
        }
    }

    Write-Host ""
    if ($issues -eq 0) {
        Write-Host "  No dead redirects, orphaned pointers, or environment-mutating session hooks found" -ForegroundColor Green
        Write-Host "  in User/Machine/process env vars or $env:USERPROFILE\.claude\settings*.json." -ForegroundColor Green
        if ($projectFound -eq 0) {
            Write-Host "  Not checked: this directory's own .claude\settings*.json - $(Get-Location) doesn't have one, or you're not in a project root. cd there and re-run if you expect one." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  $issues issue(s) found." -ForegroundColor Yellow
        if ($orphans -gt 0) {
            Write-Host "  $orphans of them are ORPHANED POINTERS — your saved config is already correct and clearing it again will not help." -ForegroundColor Yellow
            Write-Host "  Sign out and back in (or reboot). That is the only thing that rebuilds a running session's environment." -ForegroundColor Yellow
        } else {
            Write-Host "  After clearing, restart every open shell and every running agent CLI — they hold stale copies of the environment." -ForegroundColor Yellow
        }
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
# Write-Host "  ai-route         Advisory: is this task local-safe or cloud-only? (ai-route <description> [-Files <path[]>])" -ForegroundColor Gray
# Write-Host "  ai-handoff       Append the current ai-route decision to .ai-context\SESSION_STATE.md" -ForegroundColor Gray
# Write-Host "  ai-auth          Show auth status" -ForegroundColor Gray
# Write-Host "  ai-auth-set      Store API key for cloud provider" -ForegroundColor Gray
# Write-Host "  ai-cache         Show/clear prompt cache" -ForegroundColor Gray
# Write-Host "  ai-config        Show full platform configuration" -ForegroundColor Gray
# Write-Host ""
# Write-Host "  ollama serve     BLOCKED — use ai-start instead" -ForegroundColor DarkGray
# Write-Host "  ollama <other>   Passed through to ollama.exe normally" -ForegroundColor DarkGray