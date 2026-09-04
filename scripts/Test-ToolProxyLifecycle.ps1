# Self-check for Start-ToolProxy.ps1 / Stop-ToolProxy.ps1 (AIRLOCK_DEEP_REVIEW_e5121b4.md
# PROXY-003 and PROXY-004). Verifies against disposable temp fixtures and real throwaway
# processes, never the real ~/.ai-platform state, that:
#   1. Stop-ToolProxy.ps1 refuses to kill a process whose command line doesn't match the
#      tool-proxy's own uvicorn invocation (stale/recycled PID protection).
#   2. Stop-ToolProxy.ps1 does kill a process whose command line does match.
#   3. Start-ToolProxy.ps1 -Force stops an existing identity-matched proxy before relaunching,
#      rather than leaving it running while a replacement is attempted.
# Run: pwsh -File scripts/Test-ToolProxyLifecycle.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartScript = Join-Path $ScriptDir "Start-ToolProxy.ps1"
$StopScript = Join-Path $ScriptDir "Stop-ToolProxy.ps1"

$failures = 0
$fixturePlatformDir = Join-Path $env:TEMP "air-test-toolproxy-$PID"

function New-DummyProcess {
    # A real, harmless child process. Passing "uvicorn"/"app.main:app" as inert arguments
    # to a no-op PowerShell command makes them show up in Win32_Process.CommandLine, which
    # is exactly the substring match Test-ToolProxyProcessIdentity performs - a safe stand-in
    # for a real uvicorn launch without needing FastAPI/uvicorn actually installed.
    param([switch]$MatchIdentity)
    # NOT a comment - '#' would swallow the rest of the line including Start-Sleep. A
    # no-op string assignment keeps the marker text in the real command line while still
    # letting the process actually run.
    $cmd = if ($MatchIdentity) {
        "`$null = 'uvicorn app.main:app fake-proxy-under-test'; Start-Sleep -Seconds 120"
    } else {
        "`$null = 'unrelated-process fake-proxy-under-test'; Start-Sleep -Seconds 120"
    }
    $exe = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }
    $startParams = @{
        FilePath     = $exe
        ArgumentList = @("-NoProfile", "-Command", $cmd)
        PassThru     = $true
    }
    if ($IsWindows) { $startParams.WindowStyle = 'Hidden' }
    $proc = Start-Process @startParams
    Start-Sleep -Milliseconds 300  # let Win32_Process see the command line
    return $proc
}

function Remove-Fixtures {
    Remove-Item $fixturePlatformDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Testing Start-ToolProxy.ps1 / Stop-ToolProxy.ps1 lifecycle..." -ForegroundColor Cyan

# Case 1: Stop-ToolProxy.ps1 must not kill a PID whose command line doesn't match.
Remove-Fixtures
New-Item -ItemType Directory -Path $fixturePlatformDir -Force | Out-Null
$unrelated = New-DummyProcess
try {
    @{ pid = $unrelated.Id; port = 19999 } | ConvertTo-Json | Set-Content "$fixturePlatformDir\.tool-proxy-port.json"
    & $StopScript -PlatformDir $fixturePlatformDir *> $null

    Start-Sleep -Milliseconds 300
    $stillAlive = Get-Process -Id $unrelated.Id -ErrorAction SilentlyContinue
    if ($stillAlive) {
        Write-Host "PASS: identity mismatch -> unrelated process left running" -ForegroundColor Green
    } else {
        Write-Host "FAIL: Stop-ToolProxy killed a process that did not match its own identity check" -ForegroundColor Red
        $failures++
    }
} finally {
    Stop-Process -Id $unrelated.Id -Force -ErrorAction SilentlyContinue
}

# Case 2: Stop-ToolProxy.ps1 does kill a PID whose command line matches.
Remove-Fixtures
New-Item -ItemType Directory -Path $fixturePlatformDir -Force | Out-Null
$matching = New-DummyProcess -MatchIdentity
try {
    @{ pid = $matching.Id; port = 19999 } | ConvertTo-Json | Set-Content "$fixturePlatformDir\.tool-proxy-port.json"
    & $StopScript -PlatformDir $fixturePlatformDir *> $null

    Start-Sleep -Milliseconds 300
    $stillAlive = Get-Process -Id $matching.Id -ErrorAction SilentlyContinue
    if (-not $stillAlive) {
        Write-Host "PASS: identity match -> proxy process stopped" -ForegroundColor Green
    } else {
        Write-Host "FAIL: Stop-ToolProxy left a real, identity-matched proxy process running" -ForegroundColor Red
        $failures++
        Stop-Process -Id $matching.Id -Force -ErrorAction SilentlyContinue
    }
} catch {
    Stop-Process -Id $matching.Id -Force -ErrorAction SilentlyContinue
    throw
}

# Case 3: Start-ToolProxy.ps1 -Force stops an existing identity-matched proxy before
# attempting to relaunch, rather than leaving it running underneath a failed replacement.
Remove-Fixtures
New-Item -ItemType Directory -Path "$fixturePlatformDir\tool-proxy\app" -Force | Out-Null
Set-Content "$fixturePlatformDir\tool-proxy\app\main.py" "# stub, not a real app - this test only exercises the pre-launch stop logic"
Set-Content "$fixturePlatformDir\tool-proxy\requirements.txt" ""
$existing = New-DummyProcess -MatchIdentity
try {
    @{ pid = $existing.Id; port = 19998 } | ConvertTo-Json | Set-Content "$fixturePlatformDir\.tool-proxy-port.json"

    # Run in the background - the script will go on to fail at venv/uvicorn setup against
    # the stub app, which is irrelevant to what this case checks. Give it a few seconds to
    # reach and execute the -Force stop-existing logic, then stop waiting on it.
    $job = Start-Job -ScriptBlock {
        param($script, $platformDir)
        & $script -Force -Port 19998 -PlatformDir $platformDir *> $null
    } -ArgumentList $StartScript, $fixturePlatformDir

    $stopped = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        if (-not (Get-Process -Id $existing.Id -ErrorAction SilentlyContinue)) { $stopped = $true; break }
    }

    if ($stopped) {
        Write-Host "PASS: Start-ToolProxy -Force stopped the existing proxy before relaunching" -ForegroundColor Green
    } else {
        Write-Host "FAIL: Start-ToolProxy -Force left the existing identity-matched proxy running" -ForegroundColor Red
        $failures++
    }

    Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue
} finally {
    Stop-Process -Id $existing.Id -Force -ErrorAction SilentlyContinue
}

Remove-Fixtures

if ($failures -eq 0) {
    Write-Host ""
    Write-Host "All tool-proxy lifecycle checks passed" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host "$failures check(s) failed" -ForegroundColor Red
    exit 1
}
