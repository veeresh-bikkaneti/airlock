# Self-check for agent-profile-helpers.ps1 (ADR-012 Phase B).
# Run: pwsh -File scripts/Test-AgentProfileHelpers.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "agent-profile-helpers.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing agent-profile-helpers.ps1..." -ForegroundColor Cyan

# --- Get-AirlockProfileCatalogue / Test-AirlockProfileSchema against the real catalogue ---

$catalogue = Get-AirlockProfileCatalogue -Path (Join-Path $ScriptDir "..\config\agent-profiles.json")
Assert-True ($catalogue.Count -eq 2) "config/agent-profiles.json parses with the expected candidate count"
foreach ($p in $catalogue) {
    $schema = Test-AirlockProfileSchema -Profile $p
    Assert-True $schema.Valid "profile '$($p.profileId)' in the real catalogue passes schema validation"
}

$missingField = $catalogue[0] | Select-Object -ExcludeProperty minimumFreeVramGiB *
$badSchema = Test-AirlockProfileSchema -Profile $missingField
Assert-True (-not $badSchema.Valid) "a profile missing a required field fails schema validation"
Assert-True ($badSchema.MissingFields -contains 'minimumFreeVramGiB') "the specific missing field is named"

$notCandidateOnly = $catalogue[0] | Select-Object *
$notCandidateOnly.candidateOnly = $false
$badVerdict = Test-AirlockProfileSchema -Profile $notCandidateOnly
Assert-True (-not $badVerdict.Valid) "a profile claiming candidateOnly=false is rejected - the catalogue never contains a passing verdict"

# --- Resolve-AirlockProfileSelection: explicit-selection rule ---

$sel1 = Resolve-AirlockProfileSelection -AvailableProfiles $catalogue -InstalledProfileIds @('ollama-gemma4-12b')
Assert-True ($null -eq $sel1.Selected) "an installed-but-unrequested profile is never auto-selected"

$sel2 = Resolve-AirlockProfileSelection -RequestedProfileId 'ollama-gemma4-12b' -AvailableProfiles $catalogue
Assert-True ($sel2.Selected.profileId -eq 'ollama-gemma4-12b') "an explicitly requested, catalogued profile is selected"

$sel3 = Resolve-AirlockProfileSelection -RequestedProfileId 'does-not-exist' -AvailableProfiles $catalogue
Assert-True ($null -eq $sel3.Selected) "requesting a profile not in the catalogue selects nothing"

# --- Resolve-AirlockFitState: three independent states, all required for coding-ready ---

$fitAll = Resolve-AirlockFitState -FreeVramGiB 12 -MinimumFreeVramGiB 10 -Residency 'Full' -TransportReturnedValidToolEvents $true -HarnessContractPassed $true
Assert-True $fitAll.CodingReady "all three states true -> coding-ready"

$fitLowVram = Resolve-AirlockFitState -FreeVramGiB 8 -MinimumFreeVramGiB 10 -Residency 'Full' -TransportReturnedValidToolEvents $true -HarnessContractPassed $true
Assert-True (-not $fitLowVram.ArtifactFit) "free VRAM below the policy floor -> artifact-fit false"
Assert-True (-not $fitLowVram.CodingReady) "artifact-fit false alone blocks coding-ready even if transport/harness pass"

$fitCpuOnly = Resolve-AirlockFitState -FreeVramGiB 20 -MinimumFreeVramGiB 10 -Residency 'CpuOnly' -TransportReturnedValidToolEvents $true -HarnessContractPassed $true
Assert-True (-not $fitCpuOnly.ArtifactFit) "sufficient VRAM number but CPU-only residency still fails artifact-fit - a spilled model never 'fits' on paper"

$fitBadTransport = Resolve-AirlockFitState -FreeVramGiB 12 -MinimumFreeVramGiB 10 -Residency 'Full' -TransportReturnedValidToolEvents $false -HarnessContractPassed $true
Assert-True (-not $fitBadTransport.CodingReady) "transport-fit false blocks coding-ready even with everything else true"

$fitBadHarness = Resolve-AirlockFitState -FreeVramGiB 12 -MinimumFreeVramGiB 10 -Residency 'Full' -TransportReturnedValidToolEvents $true -HarnessContractPassed $false
Assert-True (-not $fitBadHarness.CodingReady) "harness-fit false blocks coding-ready even with everything else true"

# --- Resolve-AirlockNextTransport: profile order, proxy-only-after-direct-failure, no-proxy-after-direct-pass ---

$order = @('ollama-native', 'ollama-openai-direct', 'ollama-openai-proxy')

$t1 = Resolve-AirlockNextTransport -TransportCandidatesInOrder $order -AttemptedResults @{}
Assert-True ($t1.Transport -eq 'ollama-native') "with nothing tried yet, the next transport is the first in profile order"

$t2 = Resolve-AirlockNextTransport -TransportCandidatesInOrder $order -AttemptedResults @{ 'ollama-native' = 'Pass' }
Assert-True ($t2.Done -and $t2.Verdict -eq 'Pass' -and $t2.PassedTransport -eq 'ollama-native') "a passed direct transport stops the attempt - never continues to try the proxy after a direct pass"

$t3 = Resolve-AirlockNextTransport -TransportCandidatesInOrder $order -AttemptedResults @{ 'ollama-native' = 'Fail' }
Assert-True ($t3.Transport -eq 'ollama-openai-direct') "after one direct failure, the next untried direct candidate in order is attempted next (not the proxy yet)"

$t4 = Resolve-AirlockNextTransport -TransportCandidatesInOrder $order -AttemptedResults @{ 'ollama-native' = 'Fail'; 'ollama-openai-direct' = 'Fail' }
Assert-True ($t4.Transport -eq 'ollama-openai-proxy') "proxy is attempted only after every direct candidate ahead of it has failed"

$t5 = Resolve-AirlockNextTransport -TransportCandidatesInOrder @('ollama-openai-direct', 'ollama-openai-proxy') -AttemptedResults @{ 'ollama-openai-direct' = 'Pass' }
Assert-True ($t5.Done -and $t5.PassedTransport -eq 'ollama-openai-direct') "a direct pass earlier in the order stops before ever reaching the proxy"

$t6 = Resolve-AirlockNextTransport -TransportCandidatesInOrder $order -AttemptedResults @{ 'ollama-native' = 'Fail'; 'ollama-openai-direct' = 'Fail'; 'ollama-openai-proxy' = 'Fail' }
Assert-True ($t6.Done -and $t6.Verdict -eq 'Fail') "every candidate tried and failed -> overall Fail, nothing left to try"

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures agent-profile-helpers check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All agent-profile-helpers checks passed" -ForegroundColor Green
