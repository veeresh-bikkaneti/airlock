# Self-check for ai-doctor's orphan-pointer classification in profile-helpers.ps1 (AIR-H1).
# Run: pwsh -File scripts/Test-Doctor.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $ScriptDir "profile-helpers.ps1") *> $null

$failures = 0

function Get-DoctorOutput {
    $out = ai-doctor *>&1 | Out-String
    return $out
}

Write-Host "Testing ai-doctor orphan classification..." -ForegroundColor Cyan

# Case 1: clean shell -> no ORPHANED POINTER. If this fails, the shell running the test
# already had a dead ANTHROPIC_BASE_URL/etc set before Test-Doctor.ps1 started - not this
# script's bug, but worth knowing before trusting case 2/3 below.
$before = Get-DoctorOutput
if ($before -match 'ORPHANED POINTER:') {
    Write-Host "FAIL: clean shell reported an orphan (env pre-polluted by caller?)" -ForegroundColor Red
    $failures++
} else {
    Write-Host "PASS: clean shell -> no orphan" -ForegroundColor Green
}

# Case 2: dead port at Process scope only, User/Machine clean -> ORPHANED POINTER, a carrier
# chain, and a sign-out/reboot (or restart-the-carrier) remediation. This is the acceptance
# bar from AIR-H1: a redirect that outlived the platform must not be misreported as a simple
# dead redirect you can clear in this shell and forget.
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:9999"
try {
    $out = Get-DoctorOutput
    if ($out -notmatch 'ORPHANED POINTER: ANTHROPIC_BASE_URL') {
        Write-Host "FAIL: dead process-scope redirect did not classify as ORPHANED POINTER" -ForegroundColor Red
        $failures++
    } elseif ($out -notmatch 'Carrier chain:') {
        Write-Host "FAIL: orphan case did not print a carrier chain" -ForegroundColor Red
        $failures++
    } elseif ($out -notmatch 'SIGN OUT|restart') {
        Write-Host "FAIL: orphan case did not print a sign-out/reboot or restart-the-carrier remediation" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: dead process-scope redirect -> ORPHANED POINTER with carrier chain and remediation" -ForegroundColor Green
    }
} finally {
    Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
}

# Case 3: bare host, no explicit port. [uri]"http://127.0.0.1" defaults .Port to 80 (verified
# against .NET behavior) - probing that implicit port instead of skipping would silently test
# the wrong thing. AIR-H1 fix: skip scopes whose raw value has no explicit ":port".
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1"
try {
    $out = Get-DoctorOutput
    if ($out -match 'ANTHROPIC_BASE_URL') {
        Write-Host "FAIL: bare-host redirect (no explicit port) should be skipped, not probed on the implicit default port" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: bare-host redirect (no explicit port) skipped rather than misprobed" -ForegroundColor Green
    }
} finally {
    Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures ai-doctor check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All ai-doctor checks passed" -ForegroundColor Green
