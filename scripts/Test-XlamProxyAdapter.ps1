# Self-check for runtime-adapters/xlam-proxy.ps1 (ADR-013).
# Covers the pure decision logic and port/base-URL helpers only -
# Start-XlamProxyRuntime/Get-XlamProxyInspection/Stop-XlamProxyIfOwned
# require a real llama-server binary, Python, and GPU - see the ADR-013
# design doc and the live capability contract run for what proves those.
# Run: pwsh -File scripts/Test-XlamProxyAdapter.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "runtime-adapters" "xlam-proxy.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing runtime-adapters/xlam-proxy.ps1..." -ForegroundColor Cyan

# --- Resolve-XlamProxyEndpointMode: single openai-direct candidate for every harness ---

foreach ($h in @('opencode', 'pi-worker', 'aider', 'openclaw')) {
    $mode = Resolve-XlamProxyEndpointMode -Harness $h
    Assert-True (($mode.TransportCandidates -join ',') -eq 'openai-direct') "$h gets exactly one transport candidate: openai-direct"
}

# --- Get-AirlockXlamProxyBaseUrl: conventional default port, snapshot overrides it ---

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-xlamproxy-adapter-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $stateDir = Join-Path $workDir "state"
    New-Item -Path $stateDir -ItemType Directory -Force | Out-Null

    $noSnapshot = Get-AirlockXlamProxyBaseUrl -PlatformDir $workDir
    Assert-True ($noSnapshot -eq "http://127.0.0.1:12348") "with no xlam-proxy-instance.json, base URL falls back to the conventional default port 12348"

    Set-Content -Path (Join-Path $stateDir "xlam-proxy-instance.json") -Value '{"proxyPort":45123}' -Encoding utf8NoBOM
    $withSnapshot = Get-AirlockXlamProxyBaseUrl -PlatformDir $workDir
    Assert-True ($withSnapshot -eq "http://127.0.0.1:45123") "with an xlam-proxy-instance.json snapshot present, the recorded proxy port is used"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Stop-XlamProxyIfOwned: no recorded instance -> refused, nothing to stop ---

$stopWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-xlamproxy-stop-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $stopWorkDir -ItemType Directory -Force | Out-Null
try {
    $stopResult = Stop-XlamProxyIfOwned -PlatformDir $stopWorkDir
    Assert-True (-not $stopResult.Stopped) "Stop-XlamProxyIfOwned with no recorded instance file refuses to stop anything"
} finally {
    Remove-Item -Path $stopWorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Get-XlamProxyInspection: unreachable base URL -> Reachable=false, never throws ---

$unreachable = Get-XlamProxyInspection -BaseUrl "http://127.0.0.1:1" -TimeoutSec 2
Assert-True (-not $unreachable.Reachable) "Get-XlamProxyInspection against an unreachable port returns Reachable=false, not an exception"

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures xlam-proxy adapter check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All xlam-proxy adapter checks passed" -ForegroundColor Green
exit 0
