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

# Test sizing ceiling: verify it uses free VRAM when a GPU is present, else free RAM.
# Regression test for ADR-005 (supersedes ADR-001 decision point 3): a model that spills
# to CPU still "runs" but is too slow for an interactive agentic loop to be usable, so GPU
# fit - not RAM fit - is the ceiling whenever a GPU exists.
Write-Host ""
Write-Host "Testing model sizing ceiling (GPU vs RAM priority)..." -ForegroundColor Cyan

$sizingTests = @(
    @{
        name   = "4GB GPU free, 32GB RAM free (should return 4 - GPU is the ceiling)"
        resources = @{ FreeMemGB = 32; GpuTotalGB = 4; GpuFreeGB = 4 }
        expect = 4
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

# Test the "prefer already-installed model" tiebreak added alongside the VRAM fix
# (PBI-airlock-local-fallback-architecture, child item 1): don't pull a bigger model
# when a smaller one that fits is already on disk.
Write-Host ""
Write-Host "Testing installed-model preference..." -ForegroundColor Cyan

$installTests = @(
    @{
        name      = "30B and 7B both fit, only 7B installed -> pick installed 7B, not bigger 30B"
        gb        = 22
        installed = @("qwen2.5-coder:7b")
        expect    = "qwen2.5-coder:7b"
    }
    @{
        name      = "30B and 7B both fit, nothing installed -> pick biggest (unchanged default)"
        gb        = 22
        installed = @()
        expect    = "qwen3-coder:30b"
    }
)

foreach ($test in $installTests) {
    $selection = Select-BestCuratedModel -AvailableGB $test.gb -ModelsConfig $modelsConfig -InstalledModels $test.installed
    if ($selection.Model -ne $test.expect) {
        Write-Host "FAIL: $($test.name) -> got '$($selection.Model)', expected '$($test.expect)'" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($test.name) -> $($selection.Model)" -ForegroundColor Green
    }
}

# Test agentic-reliability disclosure (PBI-002/ADR-014): supportsFunctionCalling is an
# API-capability flag, not a reliability signal - every curated coding model has it set
# true, including qwen2.5-coder:7b, which is live-proven unreliable at tool-calling.
# The selector must surface the known-issue note for the models that have one, and stay
# silent for a model with no disclosed issue.
Write-Host ""
Write-Host "Testing agentic-reliability note disclosure..." -ForegroundColor Cyan

$reliabilityTests = @(
    @{ name = "Only qwen2.5-coder:7b fits -> its known-unreliable note surfaces"; gb = 10; expectNote = $true }
    @{ name = "devstral-small-2:24b fits and wins -> no note (no known issue disclosed)"; gb = 20; expectNote = $false }
)

foreach ($test in $reliabilityTests) {
    $selection = Select-BestCuratedModel -AvailableGB $test.gb -ModelsConfig $modelsConfig
    $hasNote = [bool]$selection.ReliabilityNote
    if ($hasNote -ne $test.expectNote) {
        Write-Host "FAIL: $($test.name) -> model '$($selection.Model)', note present=$hasNote, expected=$($test.expectNote)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($test.name) -> $($selection.Model)" -ForegroundColor Green
    }
}

if ($failures -gt 0) { exit 1 }
Write-Host ""
Write-Host "All model-selection checks passed" -ForegroundColor Green
