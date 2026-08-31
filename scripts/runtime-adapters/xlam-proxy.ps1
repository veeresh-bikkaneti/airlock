# scripts/runtime-adapters/xlam-proxy.ps1 — ADR-013
# xlam-proxy runtime adapter: orchestrates llama.cpp (via the existing
# llamacpp.ps1 adapter, reused not duplicated) plus a Python FastAPI
# translation proxy (xlam-proxy/app/main.py) that speaks xLAM-7b-fc-r's own
# native prompt format on llama.cpp's raw /completion endpoint. Distinct
# from llamacpp.ps1's own adapter because this proxy does NOT trust
# llama-server's --jinja chat-template rendering the way a bare llama.cpp
# profile does - see docs/superpowers/specs/2026-08-30-xlam-proxy-implementation-design.md
# for the full design rationale (no Resolve-LlamaCppTemplateVerification
# marker-allowlist check here; correctness comes from the proxy's own fixed
# code, verified by the ADR-012 capability contract itself).
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by a dot-sourced file elsewhere in the chain reassigning the same name.
. (Join-Path $PSScriptRoot ".." "agent-state-helpers.ps1")
. (Join-Path $PSScriptRoot "adapter-contract-helpers.ps1")
. (Join-Path $PSScriptRoot "llamacpp.ps1")

# Fixed Airlock-chosen port (next after tool-proxy's 12347) - unlike bare
# llama-server, this proxy is fully Airlock-owned code and can have a stable
# conventional port rather than an ask-the-OS ephemeral one.
$Script:DefaultXlamProxyPort = 12348

# §3-equivalent: single OpenAI-compatible route for every harness, same
# reasoning as Resolve-LlamaCppEndpointMode - this proxy exposes exactly one
# route (/v1/chat/completions), no native/proxy split to try.
function Resolve-XlamProxyEndpointMode {
    param([Parameter(Mandatory)][ValidateSet('opencode', 'pi-worker', 'aider', 'openclaw')][string]$Harness)
    return [pscustomobject]@{ TransportCandidates = @('openai-direct'); Reason = "$Harness reaches xlam-proxy's single OpenAI-compatible /v1/chat/completions route - no native route or proxy fallback exists." }
}

function Get-AirlockXlamProxyBaseUrl {
    param([string]$PlatformDir = "$env:USERPROFILE\.ai-platform")
    $stateFile = Join-Path $PlatformDir "state" "xlam-proxy-instance.json"
    if (Test-Path $stateFile) {
        try {
            $port = (Get-Content $stateFile -Raw | ConvertFrom-Json).proxyPort
            if ($port) { return "http://127.0.0.1:$port" }
        } catch { }
    }
    return "http://127.0.0.1:$Script:DefaultXlamProxyPort"
}

function Test-XlamProxyPort {
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSec = 5)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        return $c.GetAsync("$BaseUrl/health").Result.IsSuccessStatusCode
    } catch { return $false }
}

# Same JSONL audit-log shape every other Start-*.ps1/adapter uses
# (Write-LlamaCppAuditLog, Write-ToolProxyAuditLog).
function Write-XlamProxyAuditLog {
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
        provider     = "xlam-proxy"
        endpoint     = $Endpoint
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
}

# Orchestrates two processes in order: (1) llama-server on the xLAM GGUF via
# the existing Start-LlamaCppRuntime (native 4096 context, no explicit -ngl
# override - let llama.cpp's auto-fit choose GPU layers, confirmed live this
# proved more reliable than a fixed --n-gpu-layers 99 which OOM'd on this
# 16GB card), then (2) the Python proxy pointed at llama-server's own
# just-returned base URL.
function Start-XlamProxyRuntime {
    param(
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][string]$ProxyAppDir,
        [int]$Context = 4096,
        [int]$ProxyPort = 0,
        [string]$LlamaCppBinaryPath = 'llama-server',
        [string]$PlatformDir = "$env:USERPROFILE\.ai-platform",
        [int]$LlamaCppHealthTimeoutSec = 30,
        [int]$ProxyHealthTimeoutSec = 30,
        [string]$PythonPath = 'python'
    )
    $LogDir = Join-Path $PlatformDir "logs"
    $StateDir = Join-Path $PlatformDir "state"
    foreach ($dir in @($LogDir, $StateDir)) {
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    }
    $LogFile = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')

    Write-XlamProxyAuditLog -LogFile $LogFile -Action "XlamProxyStart" -Result "STARTED" -Message "Starting xlam-proxy runtime (llama-server + Python proxy)"

    # Step 1: bring up llama-server on the xLAM GGUF. No explicit -ngl
    # override in $RuntimeArgs - auto-fit decides GPU layers.
    $llamaResult = Start-LlamaCppRuntime -ModelPath $ModelPath -Context $Context -RuntimeArgs @('--jinja') `
        -PlatformDir $PlatformDir -HealthTimeoutSec $LlamaCppHealthTimeoutSec -BinaryPath $LlamaCppBinaryPath
    if (-not $llamaResult.Started) {
        Write-XlamProxyAuditLog -LogFile $LogFile -Action "XlamProxyStart" -Result "FAILED" -Message "Underlying llama-server failed to start" -Detail $llamaResult.Reason
        return [pscustomobject]@{ Started = $false; Reason = "llama-server did not start: $($llamaResult.Reason)" }
    }

    # Step 2: launch the Python proxy pointed at the llama-server base URL
    # just returned (not re-read from disk - avoids a race with a second
    # concurrent llama-server instance touching the same state file).
    $TargetProxyPort = if ($ProxyPort -gt 0) { $ProxyPort } else { $Script:DefaultXlamProxyPort }
    $proxyInstanceNonce = [guid]::NewGuid().ToString('N')

    try {
        $proxyProc = Start-Process -FilePath $PythonPath `
            -ArgumentList @('-m', 'uvicorn', 'app.main:app', '--host', '127.0.0.1', '--port', "$TargetProxyPort") `
            -WorkingDirectory $ProxyAppDir -WindowStyle Hidden -PassThru
    } catch {
        Write-XlamProxyAuditLog -LogFile $LogFile -Action "XlamProxyStart" -Result "FAILED" -Message "Failed to launch Python proxy" -Detail $_.Exception.Message
        Stop-LlamaCppIfOwned -PlatformDir $PlatformDir | Out-Null
        return [pscustomobject]@{ Started = $false; Reason = "Failed to launch Python proxy: $($_.Exception.Message)" }
    }

    $proxyBaseUrl = "http://127.0.0.1:$TargetProxyPort"
    $elapsed = 0
    $healthy = $false
    while ($elapsed -lt $ProxyHealthTimeoutSec) {
        if (Test-XlamProxyPort -BaseUrl $proxyBaseUrl) { $healthy = $true; break }
        Start-Sleep 2; $elapsed += 2
    }

    if (-not $healthy) {
        Write-XlamProxyAuditLog -LogFile $LogFile -Action "XlamProxyStart" -Result "FAILED" -Message "Proxy health check timed out after ${ProxyHealthTimeoutSec}s" -Detail "Port: $TargetProxyPort"
        Stop-Process -Id $proxyProc.Id -Force -ErrorAction SilentlyContinue
        Stop-LlamaCppIfOwned -PlatformDir $PlatformDir | Out-Null
        return [pscustomobject]@{ Started = $false; Reason = "Python proxy did not become healthy within ${ProxyHealthTimeoutSec}s on port $TargetProxyPort." }
    }

    # Record both the proxy's own identity AND the underlying llama-server's
    # port/PID (needed for correct teardown order in Stop-XlamProxyIfOwned).
    $ownerRecord = [ordered]@{
        proxyPid                = $proxyProc.Id
        proxyOwnerStartTimeTicks = $proxyProc.StartTime.ToUniversalTime().Ticks
        proxyInstanceNonce      = $proxyInstanceNonce
        proxyPort               = $TargetProxyPort
        llamaCppPid             = $llamaResult.ProcessId
        llamaCppOwnerStartTimeTicks = $llamaResult.OwnerStartTimeTicks
        llamaCppInstanceNonce   = $llamaResult.InstanceNonce
        llamaCppPort            = $llamaResult.Port
        modelPath               = $ModelPath
        context                 = $Context
        startedAt               = [DateTime]::UtcNow.ToString('o')
    }
    Write-AirlockAtomicJson -Path (Join-Path $StateDir "xlam-proxy-instance.json") -Data $ownerRecord

    Write-XlamProxyAuditLog -LogFile $LogFile -Action "XlamProxyStart" -Result "SUCCESS" -Message "xlam-proxy ready" -Endpoint "$proxyBaseUrl/v1" -Detail "nonce=$proxyInstanceNonce; llama-server=$($llamaResult.BaseUrl)"

    return [pscustomobject]@{
        Started       = $true
        BaseUrl       = $proxyBaseUrl
        ProxyPort     = $TargetProxyPort
        ProxyPid      = $proxyProc.Id
        LlamaCppBaseUrl = $llamaResult.BaseUrl
        InstanceNonce = $proxyInstanceNonce
        AuditLogPath  = $LogFile
    }
}

# No chat_template-verification step here (see design doc's "why no
# template-verification step") - this checks the proxy's own /health, not
# llama-server's /props. Correctness comes from the proxy's fixed code, not
# a trusted template identity.
function Get-XlamProxyInspection {
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSec = 10)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $resp = $c.GetAsync("$BaseUrl/health").Result
        if (-not $resp.IsSuccessStatusCode) {
            return [pscustomobject]@{ Reachable = $false; Reason = "xlam-proxy /health returned status $([int]$resp.StatusCode)." }
        }
        $body = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
        return [pscustomobject]@{ Reachable = $true; Upstream = $body.upstream; Reason = "xlam-proxy /health reachable." }
    } catch {
        return [pscustomobject]@{ Reachable = $false; Reason = "xlam-proxy /health unreachable: $($_.Exception.Message)" }
    }
}

# Stops the Python proxy first (via the same four-factor
# Resolve-AirlockStopOwnership gate every other adapter uses), then
# delegates to Stop-LlamaCppIfOwned for the underlying llama-server. Order
# matters: stopping llama-server first would leave the proxy briefly serving
# 502s to a dead upstream.
function Stop-XlamProxyIfOwned {
    param([string]$PlatformDir = "$env:USERPROFILE\.ai-platform")
    $stateFile = Join-Path $PlatformDir "state" "xlam-proxy-instance.json"
    if (-not (Test-Path $stateFile)) {
        return [pscustomobject]@{ Stopped = $false; Reason = "No recorded xlam-proxy instance - nothing this session started is on record." }
    }
    $recorded = Get-Content $stateFile -Raw | ConvertFrom-Json
    $proc = Get-Process -Id $recorded.proxyPid -ErrorAction SilentlyContinue
    $recordedOwnerAlive = [bool]$proc
    $pidMatches = [bool]$proc
    $startTimeMatches = $false
    if ($proc) {
        $startTimeMatches = ($proc.StartTime.ToUniversalTime().Ticks -eq $recorded.proxyOwnerStartTimeTicks)
    }
    $instanceNonceMatches = -not [string]::IsNullOrEmpty($recorded.proxyInstanceNonce)

    $decision = Resolve-AirlockStopOwnership -RecordedOwnerAlive $recordedOwnerAlive -PidMatches $pidMatches -StartTimeMatches $startTimeMatches -InstanceNonceMatches $instanceNonceMatches
    if (-not $decision.Allowed) {
        return [pscustomobject]@{ Stopped = $false; Reason = $decision.Reason }
    }
    Stop-Process -Id $recorded.proxyPid -Force -ErrorAction SilentlyContinue
    $llamaCppStop = Stop-LlamaCppIfOwned -PlatformDir $PlatformDir
    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Stopped = $true; Reason = $decision.Reason; LlamaCppStopped = $llamaCppStop.Stopped }
}
