# Self-check for agent-perf-probe.ps1 (vision: "Speed honesty").
# Run: pwsh -File scripts/Test-PerfProbe.ps1
# Only the pure functions are asserted here - Measure-AirlockEndpointToksPerSec
# needs a live endpoint and is exercised by the session itself, never by CI.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "agent-perf-probe.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing agent-perf-probe.ps1..." -ForegroundColor Cyan

# --- Resolve-AirlockToksPerSec ---
Assert-True ((Resolve-AirlockToksPerSec -CompletionTokens 16 -ElapsedSeconds 2.0) -eq 8.0) "16 tokens in 2s = 8.0 tok/s"
Assert-True ((Resolve-AirlockToksPerSec -CompletionTokens 30 -ElapsedSeconds 2.0) -eq 15.0) "30 tokens in 2s = 15.0 tok/s"
Assert-True ($null -eq (Resolve-AirlockToksPerSec -CompletionTokens 16 -ElapsedSeconds 0)) "zero elapsed returns null, not Infinity"
Assert-True ($null -eq (Resolve-AirlockToksPerSec -CompletionTokens 16 -ElapsedSeconds -1)) "negative elapsed returns null"
Assert-True ((Resolve-AirlockToksPerSec -CompletionTokens 0 -ElapsedSeconds 2.0) -eq 0.0) "zero tokens is 0.0 tok/s, not null"

# --- Resolve-AirlockThroughputTier (the vision's own vocabulary) ---
Assert-True ((Resolve-AirlockThroughputTier -ToksPerSec 20) -eq 'interactive') "20 tok/s is interactive"
Assert-True ((Resolve-AirlockThroughputTier -ToksPerSec 15) -eq 'interactive') "15 tok/s boundary is interactive"
Assert-True ((Resolve-AirlockThroughputTier -ToksPerSec 8) -eq 'usable') "8 tok/s is usable"
Assert-True ((Resolve-AirlockThroughputTier -ToksPerSec 5) -eq 'usable') "5 tok/s boundary is usable"
Assert-True ((Resolve-AirlockThroughputTier -ToksPerSec 2) -eq 'slow-but-real') "2 tok/s is slow-but-real, not refused"
Assert-True ((Resolve-AirlockThroughputTier -ToksPerSec $null) -eq 'unknown') "null measurement is unknown, not failed"

Write-Host ""
if ($failures -eq 0) { Write-Host "All perf-probe checks passed." -ForegroundColor Green }
else { Write-Host "$failures perf-probe check(s) FAILED." -ForegroundColor Red; exit 1 }
