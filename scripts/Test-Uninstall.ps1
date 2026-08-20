# Self-check for Uninstall-AI.ps1 (AIR-H3/AIR-H16). Verifies against disposable temp fixtures,
# never the real ~/.ai-platform or ~/.airlock-src, that:
#   1. the ai-doctor provenance check actually runs on a real (non-WhatIf) uninstall, and
#   2. ~/.airlock-src is actually removed.
# Run: pwsh -File scripts/Test-Uninstall.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$UninstallScript = Join-Path $ScriptDir "Uninstall-AI.ps1"

$failures = 0

# Disposable fixtures standing in for ~/.ai-platform and ~/.airlock-src - real script paths are
# never touched by this test.
$fixturePlatformDir = Join-Path $env:TEMP "air-test-uninstall-platform-$PID"
$fixtureSrcDir       = Join-Path $env:TEMP "air-test-uninstall-src-$PID"

function New-Fixtures {
    # profile-helpers.ps1 dot-sources sibling scripts (Get-TaskRoute.ps1 etc.) by relative
    # path, so the whole scripts/ dir is copied, not just the two files under test.
    Copy-Item $ScriptDir (Join-Path $fixturePlatformDir "scripts") -Recurse -Force
    New-Item -ItemType Directory -Path $fixtureSrcDir -Force | Out-Null
}

function Remove-Fixtures {
    Remove-Item $fixturePlatformDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $fixtureSrcDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Testing Uninstall-AI.ps1..." -ForegroundColor Cyan

# Case 1: real (non-WhatIf) run against fixtures -> the ai-doctor provenance check must still
# execute even though $PlatformDir (which contains the copy of profile-helpers.ps1 the check
# needs) is deleted first. If the check silently no-ops, this is the AIR-H16 regression.
Remove-Fixtures
New-Fixtures
try {
    $fixtureUninstall = Join-Path $fixturePlatformDir "scripts\Uninstall-AI.ps1"
    $out = & $fixtureUninstall -PlatformDir $fixturePlatformDir -SrcDir $fixtureSrcDir *>&1 | Out-String

    if ($out -match 'Could not find profile-helpers\.ps1') {
        Write-Host "FAIL: provenance check silently skipped after PlatformDir deletion" -ForegroundColor Red
        $failures++
    } elseif ($out -notmatch 'Checking this shell for a leftover platform redirect') {
        Write-Host "FAIL: provenance check step did not run at all" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: provenance check runs on a real uninstall, not just -WhatIf" -ForegroundColor Green
    }

    # Case 2: ~/.airlock-src fixture must actually be removed.
    if (Test-Path $fixtureSrcDir) {
        Write-Host "FAIL: SrcDir (.airlock-src equivalent) was not removed" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: SrcDir (.airlock-src equivalent) removed" -ForegroundColor Green
    }
} finally {
    Remove-Fixtures
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures Uninstall-AI.ps1 check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All Uninstall-AI.ps1 checks passed" -ForegroundColor Green
