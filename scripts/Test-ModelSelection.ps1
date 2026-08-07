# Self-check for the hardware-based model auto-select logic in Start-AI.ps1.
# Run: pwsh -File scripts/Test-ModelSelection.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsConfig = Get-Content (Join-Path $ScriptDir "..\config\models.json") -Raw | ConvertFrom-Json

# Load model acquisition module for Get-ModelSizingCeilingGB / Select-BestCuratedModel
. (Join-Path $ScriptDir "Get-ModelAcquisition.ps1")

# Thin wrapper over the real, pure Select-BestCuratedModel (extracted from
# Select-BestModel specifically so it's safe to call here without triggering
# Select-BestModel's network calls / audit logging / HF background downloads).
function Select-ModelForMemory([double]$availableGB) {
    $selection = Select-BestCuratedModel -AvailableGB $availableGB -ModelsConfig $modelsConfig
    if ($selection.Model) { return $selection.Model }
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

# Test sizing ceiling: verify it always uses FreeMemGB regardless of GPU presence.
# Regression test for fix: sizing should ignore GPU VRAM and always use system RAM.
Write-Host ""
Write-Host "Testing model sizing ceiling (GPU vs RAM priority)..." -ForegroundColor Cyan

$sizingTests = @(
    @{
        name   = "4GB GPU free, 32GB RAM free (should return 32, not 4)"
        resources = @{ FreeMemGB = 32; GpuTotalGB = 4; GpuFreeGB = 4 }
        expect = 32
    }
    @{
        name   = "No GPU, 16GB RAM free (should return 16)"
        resources = @{ FreeMemGB = 16; GpuTotalGB = "N/A"; GpuFreeGB = "N/A" }
        expect = 16
    }
    @{
        name   = "8GB GPU free, 8GB RAM free (should return 8, same value either way)"
        resources = @{ FreeMemGB = 8; GpuTotalGB = 8; GpuFreeGB = 8 }
        expect = 8
    }
)

foreach ($test in $sizingTests) {
    $result = Get-ModelSizingCeilingGB -Resources $test.resources
    if ($result -ne $test.expect) {
        Write-Host "FAIL: $($test.name) -> got $result, expected $($test.expect)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($test.name) -> $result GB" -ForegroundColor Green
    }
}

if ($failures -gt 0) { exit 1 }
Write-Host ""
Write-Host "All model-selection checks passed" -ForegroundColor Green
