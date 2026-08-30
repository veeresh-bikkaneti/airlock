$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Invoke-RepairLoopCapabilityContract.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing repair-loop detection logic (calling real function)..." -ForegroundColor Cyan

# Test case 1: Valid before/after repair loop (FAIL then PASS).
$validLoop = @(
    '{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...\nFAIL: 2 + 3 = 5\n1 check(s) failed.","metadata":{}}}}'
    '{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_2","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...\nPASS: 2 + 3 = 5\nAll checks passed.","metadata":{}}}}'
)
$result1 = Resolve-AirlockRepairLoopVerdict -StdoutLines $validLoop
Assert-True ($result1.RepairLoopSucceeded) "Valid loop: function returns RepairLoopSucceeded=true"

# Test case 2: Only PASS (incomplete loop).
$passOnly = @('{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...\nPASS: 2 + 3 = 5\nAll checks passed.","metadata":{}}}}')
$result2 = Resolve-AirlockRepairLoopVerdict -StdoutLines $passOnly
Assert-True (-not $result2.RepairLoopSucceeded -and $result2.TestPassDetected -and -not $result2.TestFailureDetected) "Pass-only: RepairLoopSucceeded=false"

# Test case 3: Only FAIL (incomplete loop).
$failOnly = @('{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...\nFAIL: 2 + 3 = 5\n1 check(s) failed.","metadata":{}}}}')
$result3 = Resolve-AirlockRepairLoopVerdict -StdoutLines $failOnly
Assert-True (-not $result3.RepairLoopSucceeded -and $result3.TestFailureDetected -and -not $result3.TestPassDetected) "Fail-only: RepairLoopSucceeded=false"

# Test case 4: Invalid tool filtered, valid bash loop detected.
$withInvalid = @(
    '{"type":"tool_use","part":{"type":"tool","tool":"invalid","callID":"call_x","state":{"status":"completed","input":{"command":"explore"},"metadata":{}}}}'
    '{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...\nFAIL: 2 + 3 = 5\n1 check(s) failed.","metadata":{}}}}'
    '{"type":"tool_use","part":{"type":"tool","tool":"bash","callID":"call_2","state":{"status":"completed","input":{"command":"pwsh -File Test-AddNumbers.ps1"},"output":"Testing Add-Numbers...\nPASS: 2 + 3 = 5\nAll checks passed.","metadata":{}}}}'
)
$result4 = Resolve-AirlockRepairLoopVerdict -StdoutLines $withInvalid
Assert-True ($result4.RepairLoopSucceeded -and $result4.BashToolEvents.Count -eq 2) "Invalid tool filtered: 2 bash events + loop succeeded"

# Test case 5: FixtureDir's files land in the disposable workspace (not just spec.md).
$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "repair-loop-fixture-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -Path $fixtureDir -ItemType Directory -Force | Out-Null
Set-Content -Path (Join-Path $fixtureDir "Add-Numbers.ps1") -Value "function Add-Numbers { param([int]`$a,[int]`$b) return `$a - `$b }"
try {
    $seenFiles = $null
    Invoke-AirlockRepairLoopTrial -WorkspaceRoot ([System.IO.Path]::GetTempPath()) -SpecContent "TASK: test" -FixtureDir $fixtureDir -Invoke {
        param($WorkspacePath, $SpecContent, $ColdStart)
        $script:seenFiles = Get-ChildItem -Path $WorkspacePath -Name | Sort-Object
        return @{ Passed = $true; Reason = "n/a"; StructuredTrace = @(); RepairApplied = $false; UsedValidStructuredToolEvents = $false }
    } | Out-Null
    Assert-True (($seenFiles -contains "Add-Numbers.ps1") -and ($seenFiles -contains "spec.md")) "FixtureDir files + spec.md both present in trial workspace"
} finally {
    Remove-Item -Path $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
