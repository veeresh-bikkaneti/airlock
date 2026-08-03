# Self-check for the hardware-based model auto-select logic in Start-AI.ps1.
# Run: pwsh -File scripts/Test-ModelSelection.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsConfig = Get-Content (Join-Path $ScriptDir "..\config\models.json") -Raw | ConvertFrom-Json

function Select-ModelForMemory([double]$availableGB) {
    $chosen = $null
    foreach ($candidate in $modelsConfig.fallbackOrder) {
        $sizeGB = [double]($modelsConfig.localModels.$candidate.size -replace '[^0-9.]', '')
        if ($availableGB -ge ($sizeGB * 1.2)) { $chosen = $candidate; break }
    }
    if (-not $chosen) { $chosen = $modelsConfig.fallbackOrder[-1] }
    return $chosen
}

$cases = @(
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
