# Self-check for the hardware-based model auto-select logic in Start-AI.ps1.
# Run: pwsh -File scripts/Test-ModelSelection.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsConfig = Get-Content (Join-Path $ScriptDir "..\config\models.json") -Raw | ConvertFrom-Json

function Select-ModelForMemory([double]$availableGB) {
    $candidates = foreach ($candidate in $modelsConfig.fallbackOrder) {
        $sizeGB = [double]($modelsConfig.localModels.$candidate.size -replace '[^0-9.]', '')
        [pscustomobject]@{ Name = $candidate; SizeGB = $sizeGB; Fits = ($availableGB -ge ($sizeGB * 1.2)) }
    }
    $winner = $candidates | Where-Object { $_.Fits } | Sort-Object SizeGB -Descending | Select-Object -First 1
    if ($winner) { return $winner.Name }
    return $modelsConfig.fallbackOrder[-1]
}

$cases = @(
    @{ gb = 22; expect = "qwen3-coder:30b" }
    @{ gb = 20; expect = "devstral-small-2:24b" }
    @{ gb = 10; expect = "qwen2.5-coder:7b" }
    @{ gb = 3;  expect = "qwen2.5-coder:7b" }
)

$failures = 0
foreach ($c in $cases) {
    $result = Select-ModelForMemory $c.gb
    if ($result -ne $c.expect) {
        Write-Host "FAIL: ${$c.gb}GB -> got '$result', expected '$($c.expect)'" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($c.gb)GB -> $result" -ForegroundColor Green
    }
}
if ($failures -gt 0) { exit 1 }
Write-Host "All model-selection checks passed" -ForegroundColor Green
