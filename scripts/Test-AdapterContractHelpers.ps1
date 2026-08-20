# Self-check for runtime-adapters/adapter-contract-helpers.ps1 (ADR-012
# Phase B follow-up, §5.1/§6). These are the runtime-agnostic decisions
# every adapter (Ollama, and llama.cpp/LM Studio later) shares - see
# adapter-contract-helpers.ps1's header for why they're hoisted out of
# ollama.ps1 rather than duplicated per runtime.
# Run: pwsh -File scripts/Test-AdapterContractHelpers.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "runtime-adapters" "adapter-contract-helpers.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing runtime-adapters/adapter-contract-helpers.ps1..." -ForegroundColor Cyan

# --- Resolve-AirlockAcquisitionGate ---

$g1 = Resolve-AirlockAcquisitionGate -RequiresConfirmation $true -UserConfirmed $false
Assert-True (-not $g1.Allowed) "unconfirmed acquisition requiring confirmation is refused"

$g2 = Resolve-AirlockAcquisitionGate -RequiresConfirmation $true -UserConfirmed $true
Assert-True $g2.Allowed "confirmed acquisition is allowed"

$g3 = Resolve-AirlockAcquisitionGate -RequiresConfirmation $true -UserConfirmed $true -AnotherPullAlreadyInProgress $true
Assert-True (-not $g3.Allowed) "a confirmed acquisition is still refused while another pull is already in progress - never parallel pulls"

$g4 = Resolve-AirlockAcquisitionGate -RequiresConfirmation $false
Assert-True $g4.Allowed "acquisition not requiring confirmation is allowed with no other pull in progress"

# --- Resolve-AirlockStopOwnership ---

$s1 = Resolve-AirlockStopOwnership -RecordedOwnerAlive $false -PidMatches $true -StartTimeMatches $true -InstanceNonceMatches $true
Assert-True (-not $s1.Allowed) "no live recorded owner -> stop refused (nothing to stop)"

$s2 = Resolve-AirlockStopOwnership -RecordedOwnerAlive $true -PidMatches $true -StartTimeMatches $true -InstanceNonceMatches $false
Assert-True (-not $s2.Allowed) "PID and start time match but instance nonce does not -> refused (PID reuse guard)"

$s3 = Resolve-AirlockStopOwnership -RecordedOwnerAlive $true -PidMatches $false -StartTimeMatches $true -InstanceNonceMatches $true
Assert-True (-not $s3.Allowed) "PID mismatch alone -> refused"

$s4 = Resolve-AirlockStopOwnership -RecordedOwnerAlive $true -PidMatches $true -StartTimeMatches $true -InstanceNonceMatches $true
Assert-True $s4.Allowed "PID, start time, and instance nonce all match -> stop allowed"

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures adapter-contract-helpers check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All adapter-contract-helpers checks passed" -ForegroundColor Green
exit 0
