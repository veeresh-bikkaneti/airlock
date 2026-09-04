# scripts/runtime-adapters/llamacpp.ps1 — ADR-012 §6, §6.2
# llama.cpp runtime adapter: Start, Inspect, StopIfOwned (§6's shared
# adapter operations) plus llama.cpp's single OpenAI-compatible endpoint
# mode (§6.2 / §3's support matrix: no native/proxy split the way Ollama
# has - "llama-server OpenAI-compatible /v1" is the only route). Decision
# logic is split into pure Resolve-* functions per the repo's existing
# convention (Test-VLLMViable, Resolve-ClaudeOnStash, Resolve-OllamaEndpointMode)
# so it is testable without a real llama-server/GPU. The I/O wrappers
# around them are real implementations but require a real llama-server
# binary and GPU to exercise end to end - see Test-LlamaCppAdapter.ps1 for
# what is and isn't covered by a unit test.
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by a dot-sourced file elsewhere in the chain reassigning the same name.
. (Join-Path $PSScriptRoot ".." "agent-state-helpers.ps1")
. (Join-Path $PSScriptRoot "adapter-contract-helpers.ps1")

# §3: llama-server has one OpenAI-compatible route for OpenCode/Pi/Aider,
# and only via a custom provider for OpenClaw - no native route, no proxy
# fallback the way Ollama's ollama-openai-proxy exists. A single candidate
# in every case is correct here, matching the llamacpp-qwen38-ud-q3-k-xl
# profile's own transportCandidates: ["openai-direct"] in agent-profiles.json.
function Resolve-LlamaCppEndpointMode {
    param([Parameter(Mandatory)][ValidateSet('opencode', 'pi-worker', 'aider', 'openclaw')][string]$Harness)
    if ($Harness -eq 'openclaw') {
        return [pscustomobject]@{ TransportCandidates = @('openai-direct'); Reason = "OpenClaw reaches llama-server only via a custom provider pointed at its single OpenAI-compatible /v1 route - no native route exists for llama.cpp." }
    }
    return [pscustomobject]@{ TransportCandidates = @('openai-direct'); Reason = "$Harness uses llama-server's single OpenAI-compatible /v1 route - llama.cpp has no proxy fallback or native/direct split to try." }
}

# §6.2: "Before a tool contract it checks /props for the embedded or
# configured template identity. It must fail as template_unverified if the
# runtime cannot establish the tool-capable template/parser used by the
# request." This is the whole adapter's critical decision: never silently
# proceed on an unrecognized or absent template. Pure - takes what /props
# already returned (or a reachability failure), no I/O of its own, so it is
# fully testable without a live llama-server.
function Resolve-LlamaCppTemplateVerification {
    param(
        [Parameter(Mandatory)][bool]$PropsReachable,
        [AllowEmptyString()][string]$TemplateText = '',
        [AllowEmptyString()][string]$TemplateIdentity = ''
    )
    if (-not $PropsReachable) {
        return [pscustomobject]@{ Verdict = 'template_unverified'; Reason = "/props was not reachable - cannot establish the tool-capable template/parser used by the request before a tool contract." }
    }
    if ([string]::IsNullOrWhiteSpace($TemplateText)) {
        return [pscustomobject]@{ Verdict = 'template_unverified'; Reason = "/props reported no chat_template - runtime template identity is absent, not just unrecognized." }
    }
    # Known tool-capable template markers: Hermes/ChatML-style <tool_call>,
    # generic tool_call(s) jinja blocks, Mistral's [TOOL_CALLS] sentinel, and
    # the <tools> system-block wrapper several GGUF templates use to declare
    # the tool schema. This is a recognition allowlist, not a denylist - an
    # unrecognized template fails closed rather than being assumed capable.
    $toolCapable = $TemplateText -match '(?i)(tool_call|tool_calls|\[TOOL_CALLS\]|<tools>|function_call)'
    if (-not $toolCapable) {
        return [pscustomobject]@{ Verdict = 'template_unverified'; Reason = "chat_template present (identity: '$TemplateIdentity') but contains no recognized tool-call marker - refusing to treat an unrecognized template as tool-capable." }
    }
    return [pscustomobject]@{ Verdict = 'Pass'; Reason = "chat_template (identity: '$TemplateIdentity') contains a recognized tool-call marker." }
}

# --- I/O wrappers (require a real llama-server install; not exercised by the unit suite) ---

# Same snapshot-file convention Get-AirlockOllamaBaseUrl/Get-AirlockToolProxyBaseUrl
# use in ollama.ps1, except llama.cpp has no sensible fixed default: §6.2
# requires an Airlock-selected port per start (see Get-AirlockFreeLoopbackPort),
# not a well-known default the way Ollama's 11434 or Airlock's 12345 are - so
# with no recorded instance there is nothing to fall back to.
function Get-AirlockLlamaCppBaseUrl {
    param([string]$PlatformDir = "$env:USERPROFILE\.ai-platform")
    $stateFile = Join-Path $PlatformDir "state" "llamacpp-instance.json"
    if (Test-Path $stateFile) {
        try {
            $port = (Get-Content $stateFile -Raw | ConvertFrom-Json).port
            if ($port) { return "http://127.0.0.1:$port" }
        } catch { }
    }
    return $null
}

# Ask the OS for a free loopback port rather than guessing a fixed one -
# §6.2 requires "an Airlock-selected port", and llama.cpp (unlike Ollama)
# has no single conventional default to adopt/reuse.
function Get-AirlockFreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Test-LlamaCppPort {
    param([Parameter(Mandatory)][string]$BaseUrl)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(5)
        return $c.GetAsync("$BaseUrl/health").Result.IsSuccessStatusCode
    } catch { return $false }
}

# Same JSONL audit-log shape every other Start-*.ps1/adapter uses
# (Start-ToolProxy.ps1, Start-VLLM.ps1) - one file per day under
# $PlatformDir\logs, one compact JSON object per line.
function Write-LlamaCppAuditLog {
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('STARTED', 'SUCCESS', 'WARNING', 'FAILED')][string]$Result,
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
        provider     = "llama.cpp"
        endpoint     = $Endpoint
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
}

# §6 Start + §6.2: loopback host, Airlock-selected port, --jinja, the
# selected artifact/model alias, an explicit context limit, an explicit
# GPU-layer policy, a recorded KV-cache policy, a random process instance
# nonce, and a JSONL audit location. GPU-layer policy (and any other
# runtime flags such as --flash-attn) come through as $RuntimeArgs exactly
# as the profile declares them (config/agent-profiles.json's runtimeArgs
# for llamacpp-qwen38-ud-q3-k-xl: ["--jinja", "--flash-attn", "--n-gpu-layers", "all"])
# rather than being reinvented here - --jinja is added only if the profile
# somehow omitted it, since the ADR mandates it unconditionally.
function Start-LlamaCppRuntime {
    param(
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][int]$Context,
        [string[]]$RuntimeArgs = @('--jinja'),
        [string]$KvCacheMode = 'default',
        [int]$Port = 0,
        [string]$BinaryPath = 'llama-server',
        [string]$PlatformDir = "$env:USERPROFILE\.ai-platform",
        [int]$HealthTimeoutSec = 300
    )
    $LogDir = Join-Path $PlatformDir "logs"
    $StateDir = Join-Path $PlatformDir "state"
    foreach ($dir in @($LogDir, $StateDir)) {
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    }
    $LogFile = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')

    $TargetPort = if ($Port -gt 0) { $Port } else { Get-AirlockFreeLoopbackPort }
    $instanceNonce = [guid]::NewGuid().ToString('N')

    $effectiveArgs = @('--host', '127.0.0.1', '--port', "$TargetPort", '-m', $ModelPath, '--ctx-size', "$Context")
    if ($RuntimeArgs -notcontains '--jinja') { $effectiveArgs += '--jinja' }
    $effectiveArgs += $RuntimeArgs

    Write-LlamaCppAuditLog -LogFile $LogFile -Action "LlamaCppStart" -Result "STARTED" -Message "Launching llama-server" -Detail "Args: $($effectiveArgs -join ' ')"

    try {
        $proc = Start-Process -FilePath $BinaryPath -ArgumentList $effectiveArgs -WindowStyle Hidden -PassThru
    } catch {
        Write-LlamaCppAuditLog -LogFile $LogFile -Action "LlamaCppStart" -Result "FAILED" -Message "Failed to launch $BinaryPath" -Detail $_.Exception.Message
        return [pscustomobject]@{ Started = $false; Reason = "Failed to launch $BinaryPath : $($_.Exception.Message)" }
    }

    $baseUrl = "http://127.0.0.1:$TargetPort"
    $elapsed = 0
    $healthy = $false
    while ($elapsed -lt $HealthTimeoutSec) {
        if (Test-LlamaCppPort -BaseUrl $baseUrl) { $healthy = $true; break }
        Start-Sleep 2; $elapsed += 2
    }

    if (-not $healthy) {
        Write-LlamaCppAuditLog -LogFile $LogFile -Action "LlamaCppStart" -Result "FAILED" -Message "Health check timed out after ${HealthTimeoutSec}s" -Detail "Port: $TargetPort"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Started = $false; Reason = "llama-server did not become healthy within ${HealthTimeoutSec}s on port $TargetPort." }
    }

    # Same {ownerPid, ownerStartTimeTicks, instanceNonce} shape New-AirlockLock
    # records (agent-state-helpers.ps1) - Stop-LlamaCppIfOwned reads this back.
    $ownerRecord = [ordered]@{
        ownerPid            = $proc.Id
        ownerStartTimeTicks = $proc.StartTime.ToUniversalTime().Ticks
        instanceNonce       = $instanceNonce
        port                = $TargetPort
        modelPath           = $ModelPath
        context             = $Context
        kvCacheMode         = $KvCacheMode
        startedAt           = [DateTime]::UtcNow.ToString('o')
    }
    Write-AirlockAtomicJson -Path (Join-Path $StateDir "llamacpp-instance.json") -Data $ownerRecord

    Write-LlamaCppAuditLog -LogFile $LogFile -Action "LlamaCppStart" -Result "SUCCESS" -Message "llama-server ready" -Endpoint "$baseUrl/v1" -Detail "nonce=$instanceNonce"

    return [pscustomobject]@{
        Started             = $true
        BaseUrl             = $baseUrl
        ProcessId           = $proc.Id
        OwnerStartTimeTicks = $ownerRecord.ownerStartTimeTicks
        InstanceNonce       = $instanceNonce
        Port                = $TargetPort
        AuditLogPath        = $LogFile
    }
}

# §6 Inspect + §6.2's /props template check.
function Get-LlamaCppInspection {
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSec = 10)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $resp = $c.GetAsync("$BaseUrl/props").Result
        if (-not $resp.IsSuccessStatusCode) {
            $verification = Resolve-LlamaCppTemplateVerification -PropsReachable $false
            return [pscustomobject]@{ Reachable = $false; TemplateIdentity = ''; TemplateVerdict = $verification.Verdict; Reason = $verification.Reason }
        }
        $props = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
        $templateText = $props.chat_template
        $templateIdentity = ''
        if ($templateText) {
            $hashBytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($templateText))
            $templateIdentity = "sha256:" + (-join ($hashBytes | ForEach-Object { $_.ToString('x2') }))
        }
        $verification = Resolve-LlamaCppTemplateVerification -PropsReachable $true -TemplateText $templateText -TemplateIdentity $templateIdentity
        return [pscustomobject]@{
            Reachable        = $true
            TemplateIdentity = $templateIdentity
            TemplateVerdict  = $verification.Verdict
            Reason           = $verification.Reason
        }
    } catch {
        $verification = Resolve-LlamaCppTemplateVerification -PropsReachable $false
        return [pscustomobject]@{ Reachable = $false; TemplateIdentity = ''; TemplateVerdict = $verification.Verdict; Reason = $verification.Reason }
    }
}

# §6 StopIfOwned: thin wrapper over the shared Resolve-AirlockStopOwnership
# decision (adapter-contract-helpers.ps1) - stop only a process this
# session's own Start-LlamaCppRuntime recorded, verified by PID, start
# time, and instance nonce, never a bare PID from disk.
function Stop-LlamaCppIfOwned {
    param([string]$PlatformDir = "$env:USERPROFILE\.ai-platform")
    $stateFile = Join-Path $PlatformDir "state" "llamacpp-instance.json"
    if (-not (Test-Path $stateFile)) {
        return [pscustomobject]@{ Stopped = $false; Reason = "No recorded llama.cpp instance - nothing this session started is on record." }
    }
    $recorded = Get-Content $stateFile -Raw | ConvertFrom-Json
    $proc = Get-Process -Id $recorded.ownerPid -ErrorAction SilentlyContinue
    $recordedOwnerAlive = [bool]$proc
    $pidMatches = [bool]$proc
    $startTimeMatches = $false
    if ($proc) {
        $startTimeMatches = ($proc.StartTime.ToUniversalTime().Ticks -eq $recorded.ownerStartTimeTicks)
    }
    # instanceNonce is app-level bookkeeping, not visible to the OS - it is
    # read from the same recorded-state file being validated, so this is
    # always true once the file parses. Routed through
    # Resolve-AirlockStopOwnership as a real parameter (not hardcoded)
    # anyway, so every adapter exercises the identical four-factor gate.
    $instanceNonceMatches = -not [string]::IsNullOrEmpty($recorded.instanceNonce)

    $decision = Resolve-AirlockStopOwnership -RecordedOwnerAlive $recordedOwnerAlive -PidMatches $pidMatches -StartTimeMatches $startTimeMatches -InstanceNonceMatches $instanceNonceMatches
    if (-not $decision.Allowed) {
        return [pscustomobject]@{ Stopped = $false; Reason = $decision.Reason }
    }
    Stop-Process -Id $recorded.ownerPid -Force
    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Stopped = $true; Reason = $decision.Reason }
}
