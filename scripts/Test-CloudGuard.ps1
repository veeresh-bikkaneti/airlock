# Test-CloudGuard.ps1 — paid fallback stops. No network.
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "cloud-guard.ps1")

$failures = 0
function Assert-Equal($name, $actual, $expected) {
    if ($actual -ne $expected) {
        Write-Host "FAIL: $name -> '$actual' expected '$expected'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $name" -ForegroundColor Green
    }
}

$costs = @{ openrouter = 0.01; openai = 0.01; anthropic = 0.05 }
$order = @('openrouter', 'openai', 'anthropic')
$base = @{
    Enabled = $true; AllowSensitive = $false; Sensitive = $false
    MaxAttempts = 2; MaxCostUsd = 0.05; TimeoutSec = 20
    AttemptsMade = 0; SpentUsd = 0; LastHttpStatus = ''; CircuitOpen = $false
    ProvidersInCostOrder = $order; AttemptCostUsd = $costs
}

$off = Resolve-AirlockCloudDecision @base -Enabled:$false
Assert-Equal "disabled stays local" $off.Allow $false
Assert-Equal "disabled fallback is local" $off.Fallback "local"

$bad = Resolve-AirlockCloudDecision @base -MaxAttempts 0
Assert-Equal "zero attempts is invalid" $bad.Allow $false

$secret = Resolve-AirlockCloudDecision @base -Sensitive:$true
Assert-Equal "sensitive stays local" $secret.Allow $false

$first = Resolve-AirlockCloudDecision @base
Assert-Equal "first attempt is the cheap provider" $first.Provider "openrouter"
Assert-Equal "timeout is capped" $first.TimeoutSec 20

$rate = Resolve-AirlockCloudDecision @base -LastHttpStatus '429'
Assert-Equal "429 does not escalate" $rate.Allow $false
Assert-Equal "429 opens the circuit" $rate.CircuitOpen $true
Assert-Equal "429 falls back local" $rate.Fallback "local"

$bill = Resolve-AirlockCloudDecision @base -LastHttpStatus '402'
Assert-Equal "402 stops" $bill.Allow $false

$cap = Resolve-AirlockCloudDecision @base -AttemptsMade 2
Assert-Equal "third attempt is refused" $cap.Allow $false

$tight = Resolve-AirlockCloudDecision @base -MaxCostUsd 0.009
Assert-Equal "budget smaller than the cheapest attempt stops" $tight.Allow $false

$second = Resolve-AirlockCloudDecision @base -AttemptsMade 1 -SpentUsd 0.01
Assert-Equal "second attempt still the cheap tier" $second.Provider "openrouter"

if ($failures -gt 0) { exit 1 }
Write-Host ""
Write-Host "All cloud-guard checks passed" -ForegroundColor Green
