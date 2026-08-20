# Self-check for ai-doctor's source/install skew detection in profile-helpers.ps1 (AIR-H13).
# Run: pwsh -File scripts/Test-InstallDrift.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $ScriptDir "profile-helpers.ps1") *> $null

$failures = 0
$RealUserProfile = $env:USERPROFILE
$Scratch = Join-Path $env:TEMP "airlock-drift-test-$PID"

function Get-DoctorOutput {
    $out = ai-doctor *>&1 | Out-String
    return $out
}

function Reset-Scratch {
    if (Test-Path $Scratch) { Remove-Item $Scratch -Recurse -Force }
    New-Item -Path "$Scratch\.airlock-src\scripts" -ItemType Directory -Force | Out-Null
    New-Item -Path "$Scratch\.ai-platform\scripts" -ItemType Directory -Force | Out-Null
}

Write-Host "Testing ai-doctor install-skew detection..." -ForegroundColor Cyan

try {
    # Case 1: no ~/.airlock-src at all -> skipped silently, not guessed at. The function has
    # no fixed comparison point for a dev working from an arbitrary checkout, so it must not
    # report anything rather than assume drift that was never actually measured.
    $env:USERPROFILE = Join-Path $env:TEMP "airlock-drift-test-nonexistent-$PID"
    $out = Get-DoctorOutput
    if ($out -match 'INSTALL DRIFT') {
        Write-Host "FAIL: no ~/.airlock-src present but INSTALL DRIFT was still reported" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: no ~/.airlock-src -> skipped, not guessed" -ForegroundColor Green
    }

    # Case 2: source and installed identical -> no drift reported.
    $env:USERPROFILE = $Scratch
    Reset-Scratch
    Set-Content "$Scratch\.airlock-src\scripts\Foo.ps1" -Value "Write-Host 'hi'`n" -NoNewline
    Set-Content "$Scratch\.ai-platform\scripts\Foo.ps1" -Value "Write-Host 'hi'`n" -NoNewline
    $out = Get-DoctorOutput
    if ($out -match 'INSTALL DRIFT') {
        Write-Host "FAIL: identical source and installed scripts reported as drifted" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: identical source and installed -> no drift" -ForegroundColor Green
    }

    # Case 3: real content difference -> reported, with the differing filename named.
    Reset-Scratch
    Set-Content "$Scratch\.airlock-src\scripts\Foo.ps1" -Value "Write-Host 'new'`n" -NoNewline
    Set-Content "$Scratch\.ai-platform\scripts\Foo.ps1" -Value "Write-Host 'old'`n" -NoNewline
    $out = Get-DoctorOutput
    if ($out -notmatch 'INSTALL DRIFT') {
        Write-Host "FAIL: real content difference was not reported as drift" -ForegroundColor Red
        $failures++
    } elseif ($out -notmatch 'Foo\.ps1') {
        Write-Host "FAIL: drift reported but did not name the differing file" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: real content difference -> reported with filename" -ForegroundColor Green
    }

    # Case 4 (regression): CRLF-only difference must NOT be reported as drift. A fresh git
    # clone applies the checkout's core.autocrlf conversion; byte-identical source can hash
    # differently purely from line endings. Caught during development against a real clone -
    # this locks the fix in.
    Reset-Scratch
    Set-Content "$Scratch\.airlock-src\scripts\Foo.ps1" -Value "Write-Host 'hi'`r`n" -NoNewline
    Set-Content "$Scratch\.ai-platform\scripts\Foo.ps1" -Value "Write-Host 'hi'`n" -NoNewline
    $out = Get-DoctorOutput
    if ($out -match 'INSTALL DRIFT') {
        Write-Host "FAIL: CRLF-vs-LF-only difference was reported as drift (false positive)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: CRLF-vs-LF-only difference -> not reported (normalized before hashing)" -ForegroundColor Green
    }

    # Case 5: file missing from installed copy entirely -> reported as drift too.
    Reset-Scratch
    Set-Content "$Scratch\.airlock-src\scripts\Foo.ps1" -Value "Write-Host 'hi'`n" -NoNewline
    $out = Get-DoctorOutput
    if ($out -notmatch 'INSTALL DRIFT') {
        Write-Host "FAIL: script missing from installed copy was not reported as drift" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: script missing from installed copy -> reported" -ForegroundColor Green
    }
} finally {
    $env:USERPROFILE = $RealUserProfile
    if (Test-Path $Scratch) { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures install-skew check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All install-skew checks passed" -ForegroundColor Green
