# Self-check for runtime-adapters/ollama.ps1 (ADR-012 Phase B, §6/§6.1).
# Covers the pure decision logic only - Get-OllamaDiscovery/Get-OllamaInspection
# require a real Ollama install (§10.2 live acceptance suite).
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

# --- Resolve-OllamaAcquisitionGate ---

$g1 = Resolve-OllamaAcquisitionGate -RequiresConfirmation $true -UserConfirmed $false
Assert-True (-not $g1.Allowed) "unconfirmed acquisition requiring confirmation is refused"

$g2 = Resolve-OllamaAcquisitionGate -RequiresConfirmation $true -UserConfirmed $true
Assert-True $g2.Allowed "confirmed acquisition is allowed"

$g3 = Resolve-OllamaAcquisitionGate -RequiresConfirmation $true -UserConfirmed $true -AnotherPullAlreadyInProgress $true
Assert-True (-not $g3.Allowed) "a confirmed acquisition is still refused while another pull is already in progress - never parallel pulls"

$g4 = Resolve-OllamaAcquisitionGate -RequiresConfirmation $false
Assert-True $g4.Allowed "acquisition not requiring confirmation is allowed with no other pull in progress"

# --- Resolve-OllamaStopOwnership ---

$s1 = Resolve-OllamaStopOwnership -RecordedOwnerAlive $false -PidMatches $true -StartTimeMatches $true -InstanceNonceMatches $true
Assert-True (-not $s1.Allowed) "no live recorded owner -> stop refused (nothing to stop)"

$s2 = Resolve-OllamaStopOwnership -RecordedOwnerAlive $true -PidMatches $true -StartTimeMatches $true -InstanceNonceMatches $false
Assert-True (-not $s2.Allowed) "PID and start time match but instance nonce does not -> refused (PID reuse guard)"

$s3 = Resolve-OllamaStopOwnership -RecordedOwnerAlive $true -PidMatches $false -StartTimeMatches $true -InstanceNonceMatches $true
Assert-True (-not $s3.Allowed) "PID mismatch alone -> refused"

$s4 = Resolve-OllamaStopOwnership -RecordedOwnerAlive $true -PidMatches $true -StartTimeMatches $true -InstanceNonceMatches $true
Assert-True $s4.Allowed "PID, start time, and instance nonce all match -> stop allowed"

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures ollama adapter check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All ollama adapter checks passed" -ForegroundColor Green
