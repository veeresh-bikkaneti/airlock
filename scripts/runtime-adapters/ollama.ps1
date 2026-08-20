# scripts/runtime-adapters/ollama.ps1 — ADR-012 §6, §6.1
# Ollama runtime adapter: Discover, Acquire, Start, Inspect, StopIfOwned
# (§6's shared adapter operations), plus Ollama's two endpoint modes
# (§6.1). Decision logic is split into pure Resolve-* functions per the
# repo's existing convention (Test-VLLMViable, Resolve-ClaudeOnStash) so it
# is testable without a real Ollama install. The I/O wrappers around them
# are real implementations but can only be exercised against a live Ollama
# (§10.2 local live acceptance suite) - see Test-OllamaAdapter.ps1 for what
# is and isn't covered by a unit test.
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by a dot-sourced file elsewhere in the chain reassigning the same name.
. (Join-Path $PSScriptRoot ".." "agent-state-helpers.ps1")
. (Join-Path $PSScriptRoot "adapter-contract-helpers.ps1")

# Reads the live Ollama port the same way tool-proxy and
# hermes-container/run-hermes.ps1 do: a snapshot file, not a fixed value -
# Start-AI.ps1 adopts whatever port an already-running Ollama is on, and
# Airlock's own default (12345) differs from Ollama's raw default (11434).
# Hardcoding either one here reproduces the exact bug run-hermes.ps1's own
# comments describe having already fixed once.
function Get-AirlockOllamaBaseUrl {
    param([string]$PlatformDir = "$env:USERPROFILE\.ai-platform")
    $portFile = Join-Path $PlatformDir ".active-port.json"
    if (Test-Path $portFile) {
        try {
            $port = (Get-Content $portFile -Raw | ConvertFrom-Json).port
            if ($port) { return "http://127.0.0.1:$port" }
        } catch { }
    }
    return "http://127.0.0.1:12345"
}

# Same snapshot-file convention for the tool-call proxy's port
# (.tool-proxy-port.json, written by Start-ToolProxy.ps1). 12347 is that
# script's own $DefaultPort fallback, not a value invented here.
function Get-AirlockToolProxyBaseUrl {
    param([string]$PlatformDir = "$env:USERPROFILE\.ai-platform")
    $portFile = Join-Path $PlatformDir ".tool-proxy-port.json"
    if (Test-Path $portFile) {
        try {
            $port = (Get-Content $portFile -Raw | ConvertFrom-Json).port
            if ($port) { return "http://127.0.0.1:$port" }
        } catch { }
    }
    return "http://127.0.0.1:12347"
}

# §6.1: "ollama-native is for OpenClaw and uses /api/chat. ollama-openai-direct
# is for OpenCode, Pi, and Aider and uses /v1. ollama-openai-proxy starts the
# Airlock proxy only if the direct contract fails." Pure mapping from harness
# to the transport candidate order Resolve-AirlockNextTransport should try.
function Resolve-OllamaEndpointMode {
    param([Parameter(Mandatory)][ValidateSet('opencode', 'pi-worker', 'aider', 'openclaw')][string]$Harness)
    if ($Harness -eq 'openclaw') {
        return [pscustomobject]@{ TransportCandidates = @('ollama-native'); Reason = "OpenClaw uses Ollama's native /api/chat exclusively - no OpenAI-compat route for it." }
    }
    return [pscustomobject]@{ TransportCandidates = @('ollama-openai-direct', 'ollama-openai-proxy'); Reason = "$Harness uses Ollama's OpenAI-compatible /v1 route; proxy is a fallback only, tried after a direct failure." }
}

# --- I/O wrappers (require a real Ollama install; not exercised by the unit suite) ---

function Get-OllamaDiscovery {
    # §6 Discover: "Return installed models, runtime version, endpoint, and
    # available capabilities without pulling models."
    param([string]$BaseUrl = (Get-AirlockOllamaBaseUrl))
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(5)
        $tagsResp = $c.GetAsync("$BaseUrl/api/tags").Result
        $versionResp = $c.GetAsync("$BaseUrl/api/version").Result
        if (-not ($tagsResp.IsSuccessStatusCode -and $versionResp.IsSuccessStatusCode)) {
            return [pscustomobject]@{ Reachable = $false; Models = @(); Version = $null }
        }
        $tags = ($tagsResp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).models
        $version = ($versionResp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).version
        return [pscustomobject]@{ Reachable = $true; Models = $tags; Version = $version }
    } catch {
        return [pscustomobject]@{ Reachable = $false; Models = @(); Version = $null }
    }
}

function Get-OllamaInspection {
    # §6 Inspect + §6.1: model digest, effective context, template/parser
    # identity, and GPU residency (full/partial/CPU) for the running model.
    param([Parameter(Mandatory)][string]$ModelRef, [string]$BaseUrl = (Get-AirlockOllamaBaseUrl))
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        $body = [System.Net.Http.StringContent]::new((@{ name = $ModelRef } | ConvertTo-Json), [System.Text.Encoding]::UTF8, "application/json")
        $resp = $c.PostAsync("$BaseUrl/api/show", $body).Result
        if (-not $resp.IsSuccessStatusCode) {
            return [pscustomobject]@{ Found = $false }
        }
        $show = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
        $psResp = $c.GetAsync("$BaseUrl/api/ps").Result
        $residency = 'CpuOnly'
        if ($psResp.IsSuccessStatusCode) {
            $running = ($psResp.Content.ReadAsStringAsync().Result | ConvertFrom-Json).models | Where-Object { $_.name -eq $ModelRef } | Select-Object -First 1
            if ($running) {
                if ($running.size_vram -ge $running.size) { $residency = 'Full' }
                elseif ($running.size_vram -gt 0) { $residency = 'PartialOffload' }
            }
        }
        return [pscustomobject]@{
            Found      = $true
            Digest     = $show.digest
            Template   = $show.template
            Residency  = $residency
        }
    } catch {
        return [pscustomobject]@{ Found = $false }
    }
}
