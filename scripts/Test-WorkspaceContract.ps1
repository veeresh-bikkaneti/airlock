# Self-check for Invoke-WorkspaceContract.ps1 (ADR-012 Phase B, §7.2).
# Run: pwsh -File scripts/Test-WorkspaceContract.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "Invoke-WorkspaceContract.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing Invoke-WorkspaceContract.ps1..." -ForegroundColor Cyan

# --- New-AirlockWorkspaceMarker ---
$m1 = New-AirlockWorkspaceMarker
$m2 = New-AirlockWorkspaceMarker
Assert-True ($m1 -match '^[0-9a-f]{32}$') "marker is a 128-bit (32 hex char) value"
Assert-True ($m1 -ne $m2) "two markers are not the same value"

# --- Resolve-AirlockWorkspaceTrialVerdict: each failure mode is unconditional, not partial credit ---

$good = @{ ExpectedMarker = 'abc123'; OutputContent = 'abc123'; ProcessSucceeded = $true; OutOfWorkspaceRequestDetected = $false; UsedValidStructuredToolEvents = $true; ToolResultLoopDetected = $false }
Assert-True (Resolve-AirlockWorkspaceTrialVerdict @good).Passed "exact marker, no violations -> pass"

$badProc = $good.Clone(); $badProc.ProcessSucceeded = $false
Assert-True (-not (Resolve-AirlockWorkspaceTrialVerdict @badProc).Passed) "process failure -> fail"

$oob = $good.Clone(); $oob.OutOfWorkspaceRequestDetected = $true
Assert-True (-not (Resolve-AirlockWorkspaceTrialVerdict @oob).Passed) "out-of-workspace request -> fail, regardless of correct output"

$rawJson = $good.Clone(); $rawJson.UsedValidStructuredToolEvents = $false
Assert-True (-not (Resolve-AirlockWorkspaceTrialVerdict @rawJson).Passed) "no valid structured tool event (raw JSON/plain text) -> fail, not partial credit"

$loop = $good.Clone(); $loop.ToolResultLoopDetected = $true
Assert-True (-not (Resolve-AirlockWorkspaceTrialVerdict @loop).Passed) "tool-result loop -> fail"

$absent = $good.Clone(); $absent.OutputContent = $null
Assert-True (-not (Resolve-AirlockWorkspaceTrialVerdict @absent).Passed) "absent output.md -> fail"

$wrong = $good.Clone(); $wrong.OutputContent = 'not-the-marker'
Assert-True (-not (Resolve-AirlockWorkspaceTrialVerdict @wrong).Passed) "output.md content that doesn't exactly match the marker -> fail"

# --- Resolve-AirlockWorkspaceContractVerdict: pass only if ALL trials pass ---

$allPass = @([pscustomobject]@{ Passed = $true }, [pscustomobject]@{ Passed = $true }, [pscustomobject]@{ Passed = $true })
Assert-True (Resolve-AirlockWorkspaceContractVerdict -TrialResults $allPass).Passed "3 of 3 trials pass -> contract pass"

$twoOfThree = @([pscustomobject]@{ Passed = $true }, [pscustomobject]@{ Passed = $true }, [pscustomobject]@{ Passed = $false })
Assert-True (-not (Resolve-AirlockWorkspaceContractVerdict -TrialResults $twoOfThree).Passed) "2 of 3 trials pass -> contract fail, no partial credit"

Assert-True (-not (Resolve-AirlockWorkspaceContractVerdict -TrialResults @()).Passed) "zero trials -> contract fail"

# --- Full real trial + contract round trip (real filesystem, fake harness) ---

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-workspace-contract-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $goodInvoke = {
        param($WorkspacePath, $Marker)
        $seed = Get-Content (Join-Path $WorkspacePath "seed.md") -Raw
        $value = ($seed -replace '^MARKER=', '').Trim()
        Set-Content -Path (Join-Path $WorkspacePath "output.md") -Value $value -Encoding utf8NoBOM -NoNewline
        return @{ ProcessSucceeded = $true; OutOfWorkspaceRequestDetected = $false; UsedValidStructuredToolEvents = $true; ToolResultLoopDetected = $false; SanitizedInfo = "ok" }
    }
    $trial = Invoke-AirlockWorkspaceTrial -WorkspaceRoot $workDir -Invoke $goodInvoke
    Assert-True $trial.Passed "a harness that correctly echoes the marker passes one real trial"

    $trialDirs = Get-ChildItem -Path $workDir -Directory
    Assert-True ($trialDirs.Count -eq 0) "the disposable workspace is removed after the trial (cleanup in finally)"

    $contract = Invoke-AirlockWorkspaceContract -WorkspaceRoot $workDir -Invoke $goodInvoke -TrialCount 3
    Assert-True $contract.Passed "a correctly-behaving harness passes the full 3-trial contract"
    Assert-True ($contract.Trials.Count -eq 3) "the contract ran exactly 3 trials by default"

    $badInvoke = {
        param($WorkspacePath, $Marker)
        Set-Content -Path (Join-Path $WorkspacePath "output.md") -Value "wrong-value" -Encoding utf8NoBOM -NoNewline
        return @{ ProcessSucceeded = $true; OutOfWorkspaceRequestDetected = $false; UsedValidStructuredToolEvents = $true; ToolResultLoopDetected = $false; SanitizedInfo = "ok" }
    }
    $badContract = Invoke-AirlockWorkspaceContract -WorkspaceRoot $workDir -Invoke $badInvoke -TrialCount 3
    Assert-True (-not $badContract.Passed) "a harness that never echoes the correct marker fails the full contract"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures Invoke-WorkspaceContract check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All Invoke-WorkspaceContract checks passed" -ForegroundColor Green
exit 0
