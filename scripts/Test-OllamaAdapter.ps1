# Self-check for runtime-adapters/ollama.ps1 (ADR-012 Phase B, §6/§6.1).
# Covers the pure decision logic and port-snapshot resolution only -
# Get-OllamaDiscovery/Get-OllamaInspection require a real Ollama install
# (§10.2 live acceptance suite). The runtime-agnostic acquisition-gate and
# StopIfOwned checks moved to Test-AdapterContractHelpers.ps1.
# Run: pwsh -File scripts/Test-OllamaAdapter.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "runtime-adapters" "ollama.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing runtime-adapters/ollama.ps1..." -ForegroundColor Cyan

# --- Resolve-OllamaEndpointMode ---

$openclaw = Resolve-OllamaEndpointMode -Harness 'openclaw'
Assert-True (($openclaw.TransportCandidates -join ',') -eq 'ollama-native') "OpenClaw is routed to ollama-native only"

foreach ($h in @('opencode', 'pi-worker', 'aider')) {
    $r = Resolve-OllamaEndpointMode -Harness $h
    Assert-True ($r.TransportCandidates[0] -eq 'ollama-openai-direct') "$h tries ollama-openai-direct first"
    Assert-True ($r.TransportCandidates[1] -eq 'ollama-openai-proxy') "$h has ollama-openai-proxy as the fallback, in that order"
}

# --- Get-AirlockOllamaBaseUrl / Get-AirlockToolProxyBaseUrl: port-snapshot convention ---

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-ollama-adapter-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $noSnapshot = Get-AirlockOllamaBaseUrl -PlatformDir $workDir
    Assert-True ($noSnapshot -eq "http://127.0.0.1:12345") "with no .active-port.json, Ollama base URL falls back to Airlock's own default (12345), not Ollama's raw default (11434)"

    Set-Content -Path (Join-Path $workDir ".active-port.json") -Value '{"port":19999}' -Encoding utf8NoBOM
    $withSnapshot = Get-AirlockOllamaBaseUrl -PlatformDir $workDir
    Assert-True ($withSnapshot -eq "http://127.0.0.1:19999") "with a .active-port.json snapshot present, the live port is used instead of any default"

    $noProxySnapshot = Get-AirlockToolProxyBaseUrl -PlatformDir $workDir
    Assert-True ($noProxySnapshot -eq "http://127.0.0.1:12347") "with no .tool-proxy-port.json, tool-proxy base URL falls back to Start-ToolProxy.ps1's own default (12347)"

    Set-Content -Path (Join-Path $workDir ".tool-proxy-port.json") -Value '{"port":29999}' -Encoding utf8NoBOM
    $withProxySnapshot = Get-AirlockToolProxyBaseUrl -PlatformDir $workDir
    Assert-True ($withProxySnapshot -eq "http://127.0.0.1:29999") "with a .tool-proxy-port.json snapshot present, the live proxy port is used instead of the default"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures ollama adapter check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All ollama adapter checks passed" -ForegroundColor Green
exit 0
