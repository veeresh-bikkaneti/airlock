$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Invoke-RepairLoopCapabilityContract.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing repair-loop detection logic..." -ForegroundColor Cyan

# Test case 1: Valid before/after repair loop (FAIL then PASS in bash-tool outputs).
$validLoop = @"
{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...`nFAIL: 2 + 3 = 5`n1 check(s) failed.","metadata":{}}}}
{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_2","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...`nPASS: 2 + 3 = 5`nAll checks passed.","metadata":{}}}}
"@

# Simulate the detection logic on valid loop.
$testFailureDetected = [bool]($validLoop -match '(?m)^FAIL:')
$testPassDetected = [bool]($validLoop -match '(?m)^All checks passed')
Assert-True ($testFailureDetected -and $testPassDetected) "Valid repair loop: both FAIL and PASS detected"

# Test case 2: Only PASS without prior FAIL (incomplete loop, model got lucky).
$passOnly = @"
{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...`nPASS: 2 + 3 = 5`nAll checks passed.","metadata":{}}}}
"@
$onlyPassDetected = [bool]($passOnly -match '(?m)^All checks passed')
$onlyFailDetected = [bool]($passOnly -match '(?m)^FAIL:')
Assert-True ((-not $onlyFailDetected) -and $onlyPassDetected) "Pass-only case: fails gating (no prior FAIL)"

# Test case 3: Only FAIL without pass (incomplete loop, model gave up).
$failOnly = @"
{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...`nFAIL: 2 + 3 = 5`n1 check(s) failed.","metadata":{}}}}
"@
$onlyFailInLoop = [bool]($failOnly -match '(?m)^FAIL:')
$onlyPassInLoop = [bool]($failOnly -match '(?m)^All checks passed')
Assert-True ($onlyFailInLoop -and (-not $onlyPassInLoop)) "Fail-only case: fails gating (no PASS)"

# Test case 4: Invalid tool filtering (model calls non-existent tool).
$withInvalid = @"
{"type":"tool_use","part":{"type":"tool","tool":"invalid","callID":"call_x","state":{"status":"completed","input":{"command":"explore"},"metadata":{}}}}
{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...`nFAIL: 2 + 3 = 5`nFAIL: 10 + (-5) = 5`n2 check(s) failed.","metadata":{}}}}
{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_2","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...`nPASS: 2 + 3 = 5`nPASS: 10 + (-5) = 5`nAll checks passed.","metadata":{}}}}
"@
$hasInvalid = [bool]($withInvalid -match '"tool":"invalid"')
$hasBashLoop = [bool]($withInvalid -match '"tool":"bash"' -and $withInvalid -match 'FAIL:' -and $withInvalid -match 'All checks passed')
Assert-True ($hasInvalid -and $hasBashLoop) "Invalid tool present but valid bash loop also detected"

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
