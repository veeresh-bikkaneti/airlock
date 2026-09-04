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
    # ThinkPad P16 Gen 2 RTX 5000 Ada ~15 GB free: 24b (15GB) needs 18GB with
    # 20% headroom; 30b needs 21.6GB. Chat door therefore lands on 7b — which
    # is why ai-agent-start exists (ADR-016). This is the author's idle GPU.
    @{ gb = 15; expect = "qwen2.5-coder:7b" }
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
    @{
        # Lenovo ThinkPad P16 Gen 2 (21FA002BUS): i9-13950HX + RTX 5000 Ada 16GB.
        # ADR-005 measured 87.7 GB RAM free and 15 GB VRAM free on this machine.
        # Win32_VideoController.AdapterRAM is empty/0 on the Ada card (UInt32 overflow);
        # sizing must use nvidia-smi VRAM, never CIM AdapterRAM or system RAM.
        name   = "ThinkPad P16 Gen 2 RTX 5000 Ada: 15GB VRAM free, 87.7GB RAM free -> VRAM ceiling 15"
        resources = @{ FreeMemGB = 87.7; GpuTotalGB = 16.0; GpuFreeGB = 15.0 }
        expect = 15.0
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
    @{ name = "ThinkPad P16 Gen 2 idle 15GB VRAM -> 7b wins and its unreliability note surfaces"; gb = 15; expectNote = $true }
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

# Live probe: only pin ThinkPad P16 Gen 2 constants when nvidia-smi reports
# that GPU. GitHub windows-latest has no NVIDIA device, so this is skip-not-fail
# there. Idle free VRAM moves around; total VRAM, CPU threads, and "ceiling is
# VRAM not RAM" do not.
Write-Host ""
Write-Host "Testing live host snapshot (ThinkPad P16 Gen 2 / RTX 5000 Ada)..." -ForegroundColor Cyan
$nvidiaName = $null
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    try {
        $nvidiaName = (& nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1)
    } catch { $nvidiaName = $null }
}
if ($nvidiaName -match 'RTX 5000 Ada') {
    $live = Test-ResourceAvailability
    $ceiling = Get-ModelSizingCeilingGB -Resources $live
    if ($live.GpuTotalGB -ne 16) {
        Write-Host "FAIL: live GpuTotalGB is $($live.GpuTotalGB), expected 16 (16376 MiB rounded)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: live GpuTotalGB is 16 (nvidia-smi, not CIM AdapterRAM)" -ForegroundColor Green
    }
    $freeOk = ($live.GpuFreeGB -ne 'N/A') -and ([double]$live.GpuFreeGB -ge 0) -and ([double]$live.GpuFreeGB -le [double]$live.GpuTotalGB)
    if (-not $freeOk) {
        Write-Host "FAIL: live GpuFreeGB is $($live.GpuFreeGB), expected 0..16" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: live GpuFreeGB is $($live.GpuFreeGB) (idle value is not a constant)" -ForegroundColor Green
    }
    if ($ceiling -ne $live.GpuFreeGB) {
        Write-Host "FAIL: live sizing ceiling is $ceiling, expected VRAM $($live.GpuFreeGB) not RAM $($live.FreeMemGB)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: live sizing ceiling is $ceiling GB VRAM (RAM $($live.FreeMemGB) GB is ignored)" -ForegroundColor Green
    }
    if ($live.CpuCores -ne 32) {
        Write-Host "FAIL: live CpuCores is $($live.CpuCores), expected 32 (i9-13950HX threads)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: live CpuCores is 32 (i9-13950HX)" -ForegroundColor Green
    }
    $chatPick = Select-BestCuratedModel -AvailableGB $ceiling -ModelsConfig $modelsConfig
    if ([double]$ceiling -lt 18 -and $chatPick.Model -ne 'qwen2.5-coder:7b') {
        Write-Host "FAIL: live chat pick is '$($chatPick.Model)', expected qwen2.5-coder:7b below 18 GB VRAM" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: live chat pick is $($chatPick.Model)" -ForegroundColor Green
    }
    . (Join-Path $ScriptDir "agent-profile-helpers.ps1")
    $freeGiB = Get-AirlockFreeVramGiB
    $gate = Resolve-AirlockVramStartGate -FreeVramGiB $freeGiB -MinimumFreeVramGiB 14 -RequiresGpuLayersAll $true
    $expectAllow = ($null -ne $freeGiB) -and ($freeGiB -ge 14)
    if ($gate.Allowed -ne $expectAllow) {
        Write-Host "FAIL: Unsloth start gate Allowed=$($gate.Allowed) at $([math]::Round([double]$freeGiB, 2)) GiB free; expected $expectAllow" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: Unsloth 14 GiB start gate Allowed=$($gate.Allowed) at $([math]::Round([double]$freeGiB, 2)) GiB free" -ForegroundColor Green
    }
} else {
    Write-Host "SKIP: nvidia-smi did not report RTX 5000 Ada (got '$nvidiaName') - live host snapshot not asserted." -ForegroundColor Yellow
}

if ($failures -gt 0) { exit 1 }
Write-Host ""
Write-Host "All model-selection checks passed" -ForegroundColor Green
