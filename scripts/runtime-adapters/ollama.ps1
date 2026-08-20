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

# §5.1/§5.2: "The profile installer asks for confirmation before any
# multi-gigabyte download. It never starts parallel model pulls." Pure gate
# combining both rules.
function Resolve-OllamaAcquisitionGate {
    param(
        [Parameter(Mandatory)][bool]$RequiresConfirmation,
        [bool]$UserConfirmed = $false,
        [bool]$AnotherPullAlreadyInProgress = $false
    )
    if ($AnotherPullAlreadyInProgress) {
        return [pscustomobject]@{ Allowed = $false; Reason = "Another model pull is already in progress - Airlock never starts parallel pulls." }
    }
    if ($RequiresConfirmation -and -not $UserConfirmed) {
        return [pscustomobject]@{ Allowed = $false; Reason = "This acquisition requires explicit user confirmation before downloading." }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = "Confirmed and no other pull in progress." }
}

# §6: "StopIfOwned: Stop only a process created by the current session and
# verified by PID start time plus instance nonce." Extends Phase A's
# PID+StartTime ownership check (agent-state-helpers.ps1's lock takeover
# logic) with an explicit nonce, matching the ADR's exact wording -
# PROXY-004's existing cmdline-only check (Start-ToolProxy.ps1) is a weaker
# precedent this adapter intentionally does not repeat.
function Resolve-OllamaStopOwnership {
    param(
        [Parameter(Mandatory)][bool]$RecordedOwnerAlive,
        [Parameter(Mandatory)][bool]$PidMatches,
        [Parameter(Mandatory)][bool]$StartTimeMatches,
        [Parameter(Mandatory)][bool]$InstanceNonceMatches
    )
    if (-not $RecordedOwnerAlive) {
        return [pscustomobject]@{ Allowed = $false; Reason = "No live recorded owner - nothing this session started is running." }
    }
    if (-not ($PidMatches -and $StartTimeMatches -and $InstanceNonceMatches)) {
        return [pscustomobject]@{ Allowed = $false; Reason = "PID/start-time/instance-nonce do not all match the recorded owner - refusing to stop a process this session did not start." }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = "PID, start time, and instance nonce all match the recorded owner." }
}

# --- I/O wrappers (require a real Ollama install; not exercised by the unit suite) ---

function Get-OllamaDiscovery {
    # §6 Discover: "Return installed models, runtime version, endpoint, and
    # available capabilities without pulling models."
    param([string]$BaseUrl = "http://127.0.0.1:11434")
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
    param([Parameter(Mandatory)][string]$ModelRef, [string]$BaseUrl = "http://127.0.0.1:11434")
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
