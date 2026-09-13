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

# Source-level: platform-ownership probes live in ai-doctor / ai-health. Do not
# assert absence of a live 11434 warning — that port is the real machine.
$helpersSrc = Get-Content (Join-Path $ScriptDir "profile-helpers.ps1") -Raw
$doctorStart = $helpersSrc.IndexOf('function global:ai-doctor')
$healthStart = $helpersSrc.IndexOf('function global:ai-health')
if ($doctorStart -lt 0 -or $healthStart -lt 0 -or $healthStart -le $doctorStart) {
    Write-Host "FAIL: could not isolate ai-doctor / ai-health in profile-helpers.ps1" -ForegroundColor Red
    $failures++
    $doctorBody = ""
    $healthBody = ""
} else {
    $doctorBody = $helpersSrc.Substring($doctorStart, $healthStart - $doctorStart)
    $healthBody = $helpersSrc.Substring($healthStart)
}
if ($doctorBody -and $doctorBody -notmatch '11434') {
    Write-Host "FAIL: ai-doctor missing 11434 rogue-Ollama check" -ForegroundColor Red
    $failures++
} elseif ($doctorBody -and $doctorBody -notmatch 'active-agent\.json') {
    Write-Host "FAIL: ai-doctor missing active-agent.json certificate check" -ForegroundColor Red
    $failures++
} elseif ($doctorBody -and $doctorBody -notmatch '12346') {
    Write-Host "FAIL: ai-doctor missing memory-service 12346 check" -ForegroundColor Red
    $failures++
} elseif ($doctorBody) {
    Write-Host "PASS: ai-doctor source contains 11434, active-agent.json, and 12346 checks" -ForegroundColor Green
}
if ($healthBody -and $healthBody -notmatch '/v1/models') {
    Write-Host "FAIL: ai-health missing vllm /v1/models probe" -ForegroundColor Red
    $failures++
} elseif ($healthBody -and $healthBody -notmatch 'No active AI session') {
    Write-Host "FAIL: ai-health missing no-session message" -ForegroundColor Red
    $failures++
} elseif ($healthBody -and ($healthBody -match '(?s)No active AI session.*?return\b') -and ($healthBody.IndexOf('return') -lt $healthBody.IndexOf('11434'))) {
    Write-Host "FAIL: ai-health still returns before 11434/cert/memory checks when no session" -ForegroundColor Red
    $failures++
} elseif ($healthBody) {
    Write-Host "PASS: ai-health probes /v1/models and does not return before ownership checks" -ForegroundColor Green
}

# Scratch USERPROFILE: expired coding cert must warn without touching real ~/.ai-platform.
$RealUserProfile = $env:USERPROFILE
$Scratch = Join-Path $env:TEMP "airlock-doctor-cert-$PID"
try {
    New-Item -Path "$Scratch\.ai-platform\state" -ItemType Directory -Force | Out-Null
    Set-Content "$Scratch\.ai-platform\state\active-agent.json" -Value (@{
        provenAt  = "2020-01-01T00:00:00Z"
        expiresAt = "2020-01-02T00:00:00Z"
        profileId = "test"
    } | ConvertTo-Json)
    $env:USERPROFILE = $Scratch
    $out = Get-DoctorOutput
    if ($out -notmatch 'WARNING' -or $out -notmatch 'provenAt' -or $out -notmatch 'expiresAt' -or $out -notmatch 'ai-agent-start') {
        Write-Host "FAIL: expired active-agent.json did not warn with provenAt/expiresAt and ai-agent-start" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: expired active-agent.json -> WARNING with provenAt/expiresAt and ai-agent-start" -ForegroundColor Green
    }
} finally {
    $env:USERPROFILE = $RealUserProfile
    if (Test-Path $Scratch) { Remove-Item $Scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures ai-doctor check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All ai-doctor checks passed" -ForegroundColor Green
