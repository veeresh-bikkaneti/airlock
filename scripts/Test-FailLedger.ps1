# Self-check for agent-fail-ledger.ps1 (vision: "self-improve in-repo").
# Run: pwsh -File scripts/Test-FailLedger.ps1
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "agent-fail-ledger.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing agent-fail-ledger.ps1..." -ForegroundColor Cyan

$ledger = Join-Path ([System.IO.Path]::GetTempPath()) ("airlock-fail-ledger-test-" + [guid]::NewGuid().ToString('N') + ".jsonl")
if (Test-Path $ledger) { Remove-Item $ledger -Force }

# --- empty/missing ledger ---
$s0 = Get-AirlockFailLedgerSummary -LedgerPath $ledger -ProfileId 'p1' -Harness 'pi-worker'
Assert-True ($s0.Count -eq 0) "missing ledger file returns a zero-count summary, not null"
$w0 = Resolve-AirlockFailLedgerWarning -Summary $s0 -ProfileId 'p1' -Harness 'pi-worker'
Assert-True ($null -eq $w0) "zero-count summary produces no warning"

# --- write then summarize ---
$r1 = Write-AirlockFailLedgerEntry -LedgerPath $ledger -ProfileId 'p1' -ModelRef 'm1' -Runtime 'llama-server' `
    -Harness 'pi-worker' -EvidenceKey 'ek1' -Reason 'tool loop timed out'
Assert-True ($r1.Recorded) "a failure entry records successfully"
$r2 = Write-AirlockFailLedgerEntry -LedgerPath $ledger -ProfileId 'p1' -ModelRef 'm1' -Runtime 'llama-server' `
    -Harness 'pi-worker' -EvidenceKey 'ek1' -Reason 'VRAM gate refused'
Assert-True ($r2.Recorded) "a second entry for the same profile+harness records successfully"
$r3 = Write-AirlockFailLedgerEntry -LedgerPath $ledger -ProfileId 'other' -ModelRef 'm1' -Runtime 'llama-server' `
    -Harness 'pi-worker' -Reason 'unrelated profile failure'
Assert-True ($r3.Recorded) "an entry for a different profile records successfully"

$s1 = Get-AirlockFailLedgerSummary -LedgerPath $ledger -ProfileId 'p1' -Harness 'pi-worker'
Assert-True ($s1.Count -eq 2) "summary counts only matching profile+harness entries (2, not 3)"
Assert-True ($s1.LastReason -eq 'VRAM gate refused') "summary keeps the most recent matching reason"
Assert-True ($s1.LastAt -ne '') "summary keeps the most recent timestamp"

$sOther = Get-AirlockFailLedgerSummary -LedgerPath $ledger -ProfileId 'other' -Harness 'pi-worker'
Assert-True ($sOther.Count -eq 1) "a different profile gets its own count"

$sHarness = Get-AirlockFailLedgerSummary -LedgerPath $ledger -ProfileId 'p1' -Harness 'opencode'
Assert-True ($sHarness.Count -eq 0) "a different harness gets a zero count"

# --- warning text ---
$w1 = Resolve-AirlockFailLedgerWarning -Summary $s1 -ProfileId 'p1' -Harness 'pi-worker'
Assert-True ($null -ne $w1 -and $w1 -match 'failed 2 times before') "warning names the failure count"
Assert-True ($w1 -match 'VRAM gate refused') "warning carries the last reason"
Assert-True ($w1 -match "not this run's verdict") "warning states a past failure is not a refusal"

# --- reason bounding ---
$long = ('x' * 600)
$r4 = Write-AirlockFailLedgerEntry -LedgerPath $ledger -ProfileId 'p1' -ModelRef 'm1' -Runtime 'llama-server' `
    -Harness 'pi-worker' -Reason $long
$raw = Get-Content $ledger | Select-Object -Last 1 | ConvertFrom-Json
Assert-True ($raw.reason.Length -le 500) "overlong reasons are bounded at 500 chars"

# --- corrupt lines are skipped, not fatal ---
Add-Content -Path $ledger -Value 'this is not json {{{'
$s2 = Get-AirlockFailLedgerSummary -LedgerPath $ledger -ProfileId 'p1' -Harness 'pi-worker'
Assert-True ($s2.Count -eq 3) "corrupt ledger lines are skipped without breaking the summary"

Remove-Item $ledger -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($failures -eq 0) { Write-Host "All fail-ledger checks passed." -ForegroundColor Green }
else { Write-Host "$failures fail-ledger check(s) FAILED." -ForegroundColor Red; exit 1 }
