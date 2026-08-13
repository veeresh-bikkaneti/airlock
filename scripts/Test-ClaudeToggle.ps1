# Self-check for the ai-claude-on/off stash-and-restore state machine in profile-helpers.ps1.
# Run: pwsh -File scripts/Test-ClaudeToggle.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Dot-source for Resolve-ClaudeOnStash / Resolve-ClaudeOffRestore only - this does not run
# ai-start or touch real env vars, same reason Test-ModelSelection.ps1 dot-sources
# Get-ModelAcquisition.ps1 instead of calling through Start-AI.ps1.
. (Join-Path $ScriptDir "profile-helpers.ps1") *> $null

$failures = 0

# PowerShell coerces an explicit $null passed to a [string] parameter into "" - treat
# null and empty as the same "nothing was set" value for comparison purposes here.
function Test-SameOrEmpty($a, $b) {
    return ([string]::IsNullOrEmpty($a) -and [string]::IsNullOrEmpty($b)) -or ($a -eq $b)
}

Write-Host "Testing Resolve-ClaudeOnStash..." -ForegroundColor Cyan
$onCases = @(
    @{ name = "fresh shell, real key set -> stash it"; base = $null; key = "sk-ant-real"; active = $false; expectStash = $true; expectPrevKey = "sk-ant-real" }
    @{ name = "fresh shell, nothing set -> stash nulls"; base = $null; key = $null; active = $false; expectStash = $true; expectPrevKey = $null }
    @{ name = "already active (second ai-claude-on) -> do not re-stash"; base = "http://127.0.0.1:11434"; key = "ollama"; active = $true; expectStash = $false; expectPrevKey = $null }
)
foreach ($c in $onCases) {
    $r = Resolve-ClaudeOnStash -CurrentBaseUrl $c.base -CurrentApiKey $c.key -AlreadyActive $c.active
    if ($r.ShouldStash -ne $c.expectStash -or -not (Test-SameOrEmpty $r.PrevApiKey $c.expectPrevKey)) {
        Write-Host "FAIL: $($c.name) -> ShouldStash=$($r.ShouldStash) PrevApiKey=$($r.PrevApiKey)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($c.name)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Testing Resolve-ClaudeOffRestore..." -ForegroundColor Cyan
$offCases = @(
    @{ name = "was active, real prior key -> Restored"; active = $true; prevBase = $null; prevKey = "sk-ant-real"; expectMode = "Restored"; expectKey = "sk-ant-real" }
    @{ name = "was active, no prior key -> ClearedNoPriorKey"; active = $true; prevBase = $null; prevKey = $null; expectMode = "ClearedNoPriorKey"; expectKey = $null }
    @{ name = "never activated this shell -> PlainClear"; active = $false; prevBase = $null; prevKey = $null; expectMode = "PlainClear"; expectKey = $null }
)
foreach ($c in $offCases) {
    $r = Resolve-ClaudeOffRestore -WasActive $c.active -PrevBaseUrl $c.prevBase -PrevApiKey $c.prevKey
    if ($r.Mode -ne $c.expectMode -or -not (Test-SameOrEmpty $r.ApiKey $c.expectKey)) {
        Write-Host "FAIL: $($c.name) -> Mode=$($r.Mode) ApiKey=$($r.ApiKey)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($c.name)" -ForegroundColor Green
    }
}

if ($failures -gt 0) { exit 1 }
Write-Host ""
Write-Host "All Claude-toggle checks passed" -ForegroundColor Green
