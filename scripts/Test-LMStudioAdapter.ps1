# Self-check for runtime-adapters/lmstudio.ps1 (ADR-012 Phase E, §6/§6.3).
# Covers the pure decision logic (native-tool verification, API route
# choice), the port-snapshot resolution, and Stop-LMStudioIfOwned's ownership
# check (using real throwaway processes, no real LM Studio needed) -
# Get-LMStudioDiscovery/Get-LMStudioInspection's actual HTTP calls still
# require a real LM Studio install (§10.2 live acceptance suite). See the
# adapter's own header for which parts of its I/O shape are confirmed
# against LM Studio's published docs vs. still unverified without hardware.
# Run: pwsh -File scripts/Test-LMStudioAdapter.ps1
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "runtime-adapters" "lmstudio.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing runtime-adapters/lmstudio.ps1..." -ForegroundColor Cyan

# --- Resolve-LMStudioNativeToolVerification: the phase's core invariant ---

$noModel = Resolve-LMStudioNativeToolVerification -ModelReported $false -ToolTemplateKind 'unknown'
Assert-True ($noModel.Verdict -eq 'Refuse') "no model reported -> refused"

$native = Resolve-LMStudioNativeToolVerification -ModelReported $true -ToolTemplateKind 'native'
Assert-True ($native.Verdict -eq 'Pass') "a model reporting a native tool template -> Pass"

$default = Resolve-LMStudioNativeToolVerification -ModelReported $true -ToolTemplateKind 'default'
Assert-True ($default.Verdict -eq 'Refuse') "a model reporting only the default/fallback tool format -> refused, not accepted as a certification substitute"

$unknown = Resolve-LMStudioNativeToolVerification -ModelReported $true -ToolTemplateKind 'unknown'
Assert-True ($unknown.Verdict -eq 'Refuse') "an undeterminable tool-template kind -> refused, never guessed as native"

# --- Resolve-LMStudioApiRoute: profile-recorded API choice, never hardcoded ---

$chat = Resolve-LMStudioApiRoute -Profile ([pscustomobject]@{ apiMode = 'chat-completions' })
Assert-True ($chat.Path -eq '/v1/chat/completions') "profile apiMode 'chat-completions' resolves to the Chat Completions endpoint"

$responses = Resolve-LMStudioApiRoute -Profile ([pscustomobject]@{ apiMode = 'responses' })
Assert-True ($responses.Path -eq '/v1/responses') "profile apiMode 'responses' resolves to the Responses endpoint"

$missingApiMode = Resolve-LMStudioApiRoute -Profile ([pscustomobject]@{ profileId = 'lmstudio-example' })
Assert-True ($missingApiMode.Verdict -eq 'Refuse') "a profile with no apiMode recorded is refused, not guessed"

$unrecognizedApiMode = Resolve-LMStudioApiRoute -Profile ([pscustomobject]@{ apiMode = 'legacy-completions' })
Assert-True ($unrecognizedApiMode.Verdict -eq 'Refuse') "a profile with an unrecognized apiMode value is refused, not guessed"

# --- Stop-LMStudioIfOwned: PID + start-time + instance-nonce ownership check ---

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-lmstudio-adapter-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $ownerRecordPath = Join-Path $workDir "owner.json"

    $noRecord = Stop-LMStudioIfOwned -OwnerRecordPath $ownerRecordPath -SessionInstanceNonce 'nonce-a'
    Assert-True (-not $noRecord.Stopped) "no owner record on disk -> refused, nothing tracked to stop"

    # This session's own process is a safe stand-in for "a live process at a
    # known PID/start time" without spawning a real LM Studio process.
    $self = Get-Process -Id $PID
    $realOwnerRecord = [pscustomobject]@{
        ownerPid            = $PID
        ownerStartTimeTicks = $self.StartTime.ToUniversalTime().Ticks
        instanceNonce       = 'nonce-a'
    }
    ($realOwnerRecord | ConvertTo-Json) | Set-Content -Path $ownerRecordPath -Encoding utf8NoBOM

    $nonceMismatch = Stop-LMStudioIfOwned -OwnerRecordPath $ownerRecordPath -SessionInstanceNonce 'nonce-b'
    Assert-True (-not $nonceMismatch.Stopped) "recorded owner alive and PID/start-time match, but instance nonce does not -> refused"
    Assert-True (Test-Path $ownerRecordPath) "a refused stop leaves the owner record untouched"

    $staleStartTimeRecord = [pscustomobject]@{
        ownerPid            = $PID
        ownerStartTimeTicks = 123456789
        instanceNonce       = 'nonce-a'
    }
    ($staleStartTimeRecord | ConvertTo-Json) | Set-Content -Path $ownerRecordPath -Encoding utf8NoBOM
    $startTimeMismatch = Stop-LMStudioIfOwned -OwnerRecordPath $ownerRecordPath -SessionInstanceNonce 'nonce-a'
    Assert-True (-not $startTimeMismatch.Stopped) "PID matches but start time does not (PID-reuse guard) -> refused"

    $deadOwnerRecord = [pscustomobject]@{
        # A PID essentially guaranteed not to be a live process right now.
        ownerPid            = 999999
        ownerStartTimeTicks = 0
        instanceNonce       = 'nonce-a'
    }
    ($deadOwnerRecord | ConvertTo-Json) | Set-Content -Path $ownerRecordPath -Encoding utf8NoBOM
    $deadOwner = Stop-LMStudioIfOwned -OwnerRecordPath $ownerRecordPath -SessionInstanceNonce 'nonce-a'
    Assert-True (-not $deadOwner.Stopped) "no live process at the recorded PID -> refused, nothing to stop"

    # Happy path: a real, harmless throwaway process stands in for LM Studio
    # (same technique as Test-ToolProxyLifecycle.ps1's New-DummyProcess) so
    # the actual Stop-Process/Remove-Item branch is exercised, not just its
    # refusal branches.
    $dummy = Start-Process -FilePath "powershell" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 120") -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
    try {
        $matchingOwnerRecord = [pscustomobject]@{
            ownerPid            = $dummy.Id
            ownerStartTimeTicks = $dummy.StartTime.ToUniversalTime().Ticks
            instanceNonce       = 'nonce-a'
        }
        ($matchingOwnerRecord | ConvertTo-Json) | Set-Content -Path $ownerRecordPath -Encoding utf8NoBOM

        $realStop = Stop-LMStudioIfOwned -OwnerRecordPath $ownerRecordPath -SessionInstanceNonce 'nonce-a'
        Assert-True $realStop.Stopped "PID, start time, and instance nonce all match a live process -> stop reported"

        Start-Sleep -Milliseconds 300
        $stillAlive = Get-Process -Id $dummy.Id -ErrorAction SilentlyContinue
        Assert-True (-not $stillAlive) "the process reported as stopped is actually gone, not just reported as such"
        Assert-True (-not (Test-Path $ownerRecordPath)) "a confirmed stop removes the owner record"
    } finally {
        Stop-Process -Id $dummy.Id -Force -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Get-LMStudioBaseUrl: port-snapshot convention, same as the Ollama adapter ---

$workDir2 = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-lmstudio-adapter-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir2 -ItemType Directory -Force | Out-Null
try {
    $noSnapshot = Get-LMStudioBaseUrl -PlatformDir $workDir2
    Assert-True ($noSnapshot -eq "http://127.0.0.1:1234") "with no .lmstudio-port.json, base URL falls back to LM Studio's documented default port (1234)"

    Set-Content -Path (Join-Path $workDir2 ".lmstudio-port.json") -Value '{"port":18888}' -Encoding utf8NoBOM
    $withSnapshot = Get-LMStudioBaseUrl -PlatformDir $workDir2
    Assert-True ($withSnapshot -eq "http://127.0.0.1:18888") "with a .lmstudio-port.json snapshot present, the live port is used instead of the default"
} finally {
    Remove-Item -Path $workDir2 -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures lmstudio adapter check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All lmstudio adapter checks passed" -ForegroundColor Green
exit 0
