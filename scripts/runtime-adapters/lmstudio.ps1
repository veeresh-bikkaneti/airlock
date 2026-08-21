# scripts/runtime-adapters/lmstudio.ps1 — ADR-012 §6, §6.3
# LM Studio runtime adapter: Discover, Inspect (+ native-tool-template
# verification), StopIfOwned, and the Chat-Completions-vs-Responses API
# route choice (§6.3's "uses either Chat Completions or Responses API as
# recorded in the profile"). Decision logic is split into pure Resolve-*
# functions per the repo's existing convention (Resolve-OllamaEndpointMode,
# Resolve-AirlockStopOwnership) so it is testable without a real LM Studio
# install. See Test-LMStudioAdapter.ps1 for what is and isn't covered.
#
# HONESTY NOTE (read before trusting the Inspect shape below): this
# environment has no real LM Studio install, so nothing here has been
# exercised against a live server. The shapes below ARE confirmed against
# LM Studio's own published docs (fetched this session, not guessed):
#   - Discover uses /v1/models (OpenAI-compat) per ADR §6.3's own wording;
#     https://lmstudio.ai/docs/developer/openai-compat/tools confirms this
#     surface has no documented tool-template field and no documented
#     version header/endpoint anywhere in the API (see below).
#   - The native-tool signal instead comes from LM Studio's separate native
#     REST API, GET /api/v1/models (NOT /v1/models) - documented at
#     https://lmstudio.ai/docs/developer/rest/list - whose per-model response
#     includes a real `trained_for_tool_use` boolean field ("Whether the
#     model was trained for tool/function calling"), matched by the model's
#     `key` field. This is a real, named field, not an inferred one.
#   - CAVEAT that remains genuinely unverified: `trained_for_tool_use`
#     reflects the model's training, not a live confirmation that LM Studio
#     is actually applying a native tool-calling template for the current
#     session. The docs do not distinguish "native template selected" from
#     "default/fallback template selected" at the API level at all - LM
#     Studio's own UI-only signal is a "hammer badge," which has no REST
#     equivalent. This adapter treats `trained_for_tool_use=true` as the
#     best available proxy for "native," per ADR §6.3, and still refuses
#     (never fabricates a pass) when the field is absent/false/unreadable.
#   - No LM Studio endpoint or HTTP header documents a server/build version
#     anywhere in the fetched docs. Get-LMStudioDiscovery reports
#     ServerVersion=$null honestly rather than invent a header to read.
#   - Default loopback port 1234 is confirmed (every documented example uses
#     http://localhost:1234); no page states it as an explicit default, but
#     it is consistent across all examples.
# Get-LMStudioInspection is written so an absent/unrecognized signal
# degrades to 'unknown' (which Resolve-LMStudioNativeToolVerification
# refuses), never to a fabricated 'native' pass — see the phase report for
# exactly what remains unproven without live hardware.
#
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by a dot-sourced file elsewhere in the chain reassigning the same name.
. (Join-Path $PSScriptRoot ".." "agent-state-helpers.ps1")
. (Join-Path $PSScriptRoot "adapter-contract-helpers.ps1")

# Same snapshot-file convention as Get-AirlockOllamaBaseUrl/Get-AirlockToolProxyBaseUrl
# (ollama.ps1): a live port snapshot wins over any hardcoded default. 1234 is
# LM Studio's documented default local-server port, used only as a fallback
# when no snapshot exists yet.
function Get-LMStudioBaseUrl {
    param([string]$PlatformDir = "$env:USERPROFILE\.ai-platform")
    $portFile = Join-Path $PlatformDir ".lmstudio-port.json"
    if (Test-Path $portFile) {
        try {
            $port = (Get-Content $portFile -Raw | ConvertFrom-Json).port
            if ($port) { return "http://127.0.0.1:$port" }
        } catch { }
    }
    return "http://127.0.0.1:1234"
}

# §3/§6.3: LM Studio has one OpenAI-compatible route per profile-recorded
# apiMode, no native/proxy split the way Ollama has (see
# Resolve-OllamaEndpointMode / Resolve-LlamaCppEndpointMode for the same
# shape on the other two adapters). Added so Start-AgentSession.ps1 can
# dispatch on runtime without special-casing LM Studio - before this,
# nothing in the orchestrator called any function in this file at all.
function Resolve-LMStudioEndpointMode {
    param([Parameter(Mandatory)][ValidateSet('opencode', 'pi-worker', 'aider', 'openclaw')][string]$Harness)
    return [pscustomobject]@{ TransportCandidates = @('openai-direct'); Reason = "$Harness uses LM Studio's single OpenAI-compatible route (Chat Completions or Responses per profile apiMode) - no proxy fallback or native/direct split." }
}

# --- Pure decision functions ---

# ADR §6.3's core invariant for this phase: "It does not use LM Studio's
# default/fallback tool format as a certification substitute; the real
# harness contract decides." A model reporting only the fallback/default
# format - or an unrecognized/absent template kind - must be refused, never
# silently accepted as native.
function Resolve-LMStudioNativeToolVerification {
    param(
        [Parameter(Mandatory)][bool]$ModelReported,
        [Parameter(Mandatory)][ValidateSet('native', 'default', 'unknown')][string]$ToolTemplateKind
    )
    if (-not $ModelReported) {
        return [pscustomobject]@{ Verdict = 'Refuse'; Reason = "No model reported by LM Studio - nothing to verify." }
    }
    switch ($ToolTemplateKind) {
        'native' {
            return [pscustomobject]@{ Verdict = 'Pass'; Reason = "Runtime reports a native tool-calling template for the active model." }
        }
        'default' {
            return [pscustomobject]@{ Verdict = 'Refuse'; Reason = "Runtime reports only the default/fallback tool format - ADR §6.3 forbids treating this as a certification substitute." }
        }
        'unknown' {
            return [pscustomobject]@{ Verdict = 'Refuse'; Reason = "Runtime did not report a determinable tool-template kind - refusing rather than guessing native." }
        }
    }
}

# ADR §6.3: "It uses either Chat Completions or Responses API as recorded in
# the profile." Reads apiMode off the profile object itself (not a bare
# string) so a profile that never recorded one is a refusal, not a binding
# crash or a silently guessed default.
function Resolve-LMStudioApiRoute {
    param([Parameter(Mandatory)]$Profile)
    $apiMode = $null
    if ($Profile -and ($Profile.PSObject.Properties.Name -contains 'apiMode')) {
        $apiMode = $Profile.apiMode
    }
    switch ($apiMode) {
        'chat-completions' { return [pscustomobject]@{ Verdict = 'Resolved'; ApiMode = 'chat-completions'; Path = '/v1/chat/completions'; Reason = "Profile recorded apiMode 'chat-completions'." } }
        'responses' { return [pscustomobject]@{ Verdict = 'Resolved'; ApiMode = 'responses'; Path = '/v1/responses'; Reason = "Profile recorded apiMode 'responses'." } }
        default { return [pscustomobject]@{ Verdict = 'Refuse'; ApiMode = $null; Path = $null; Reason = "Profile has no recognized apiMode ('chat-completions' or 'responses') recorded - refusing to guess a route." } }
    }
}

# --- I/O wrappers (require a real LM Studio install; not exercised by the unit suite) ---

function Get-LMStudioDiscovery {
    # §6 Discover: "Return installed models, runtime version, endpoint, and
    # available capabilities without pulling models." Queries /v1/models
    # only - never triggers a model load/download.
    param([string]$BaseUrl = (Get-LMStudioBaseUrl))
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(5)
        $resp = $c.GetAsync("$BaseUrl/v1/models").Result
        if (-not $resp.IsSuccessStatusCode) {
            return [pscustomobject]@{ Reachable = $false; Models = @(); ServerVersion = $null }
        }
        $body = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
        # No LM Studio endpoint or header documents a server/build version
        # (confirmed against the fetched docs, not merely unsearched) -
        # report $null honestly. A caller wiring this into
        # Get-AirlockCapabilityEvidenceKey's mandatory RuntimeVersion
        # component will hit that gap explicitly rather than get a silently
        # invented value.
        return [pscustomobject]@{ Reachable = $true; Models = $body.data; ServerVersion = $null }
    } catch {
        return [pscustomobject]@{ Reachable = $false; Models = @(); ServerVersion = $null }
    }
}

function Get-LMStudioInspection {
    # §6 Inspect + §6.3's native-tool-template check. Confirms the model via
    # /v1/models (ADR's own wording), then reads the documented
    # `trained_for_tool_use` boolean from LM Studio's native REST API
    # (GET /api/v1/models, matched by its `key` field) - see the file
    # header's HONESTY NOTE for exactly what this field does and doesn't
    # prove. It never marks a model native merely because it loaded.
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [string]$BaseUrl = (Get-LMStudioBaseUrl)
    )
    $discovery = Get-LMStudioDiscovery -BaseUrl $BaseUrl
    if (-not $discovery.Reachable) {
        return [pscustomobject]@{ Found = $false; ModelId = $null; ToolKind = 'unknown'; Verdict = 'Refuse'; Reason = "LM Studio /v1/models unreachable." }
    }
    $model = $discovery.Models | Where-Object { $_.id -eq $ModelRef } | Select-Object -First 1
    if (-not $model) {
        return [pscustomobject]@{ Found = $false; ModelId = $null; ToolKind = 'unknown'; Verdict = 'Refuse'; Reason = "Requested model '$ModelRef' is not among LM Studio's reported models." }
    }
    $toolKind = 'unknown'
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(5)
        $nativeResp = $c.GetAsync("$BaseUrl/api/v1/models").Result
        if ($nativeResp.IsSuccessStatusCode) {
            $nativeBody = $nativeResp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
            $nativeModel = $nativeBody.data | Where-Object { $_.key -eq $ModelRef } | Select-Object -First 1
            if ($nativeModel -and ($nativeModel.PSObject.Properties.Name -contains 'trained_for_tool_use')) {
                $toolKind = if ($nativeModel.trained_for_tool_use) { 'native' } else { 'default' }
            }
        }
    } catch { }
    $verification = Resolve-LMStudioNativeToolVerification -ModelReported $true -ToolTemplateKind $toolKind
    return [pscustomobject]@{
        Found    = $true
        ModelId  = $model.id
        ToolKind = $toolKind
        Verdict  = $verification.Verdict
        Reason   = $verification.Reason
    }
}

# §6 StopIfOwned: "Stop only a process created by the current session and
# verified by PID start time plus instance nonce." Thin wrapper around the
# shared Resolve-AirlockStopOwnership (adapter-contract-helpers.ps1) - the
# owner record is whatever Start wrote: { ownerPid, ownerStartTimeTicks,
# instanceNonce }, same shape as New-AirlockLock's lock record
# (agent-state-helpers.ps1).
function Stop-LMStudioIfOwned {
    param(
        [Parameter(Mandatory)][string]$OwnerRecordPath,
        [Parameter(Mandatory)][string]$SessionInstanceNonce
    )
    if (-not (Test-Path $OwnerRecordPath)) {
        return [pscustomobject]@{ Stopped = $false; Reason = "No owner record on disk - nothing this session started is tracked." }
    }
    $owner = Get-Content $OwnerRecordPath -Raw | ConvertFrom-Json
    $proc = Get-Process -Id $owner.ownerPid -ErrorAction SilentlyContinue
    $recordedOwnerAlive = [bool]$proc
    $startTimeMatches = $false
    if ($proc) {
        $startTimeMatches = ($proc.StartTime.ToUniversalTime().Ticks -eq $owner.ownerStartTimeTicks)
    }
    $decision = Resolve-AirlockStopOwnership `
        -RecordedOwnerAlive $recordedOwnerAlive `
        -PidMatches $true `
        -StartTimeMatches $startTimeMatches `
        -InstanceNonceMatches ($owner.instanceNonce -eq $SessionInstanceNonce)

    if (-not $decision.Allowed) {
        return [pscustomobject]@{ Stopped = $false; Reason = $decision.Reason }
    }
    # Only report Stopped=$true - and only remove the owner record - once the
    # kill is confirmed. -ErrorAction SilentlyContinue here would let an
    # access-denied failure (e.g. an elevated LM Studio process) report a
    # false Stopped=$true while the process keeps running and the owner
    # record that ai-doctor-style recovery tooling would use to find the
    # orphan is already gone.
    try {
        Stop-Process -Id $owner.ownerPid -Force -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Stopped = $false; Reason = "Ownership verified but Stop-Process failed: $($_.Exception.Message)" }
    }
    Remove-Item $OwnerRecordPath -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Stopped = $true; Reason = $decision.Reason }
}
