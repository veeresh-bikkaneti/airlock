# Self-check for ConvertFrom-OllamaPullLine in Get-ModelAcquisition.ps1 - the parser
# behind live download-progress reporting in ai-port/ai-health.
# Run: pwsh -File scripts/Test-PullProgress.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "Get-ModelAcquisition.ps1") *> $null

$failures = 0

$cases = @(
    @{
        name   = "mid-download line with speed and ETA"
        line   = "pulling 797b70c4edf8:  54% ▕█████████         ▏  24 MB/ 45 MB   22 MB/s      0s"
        expect = @{ Percent = 54; Downloaded = "24 MB"; Total = "45 MB"; Speed = "22 MB/s"; Eta = "0s" }
    }
    @{
        name   = "early line, no speed/ETA yet"
        line   = "pulling 797b70c4edf8:   2% ▕                  ▏ 894 KB/ 45 MB"
        expect = @{ Percent = 2; Downloaded = "894 KB"; Total = "45 MB"; Speed = $null; Eta = $null }
    }
    @{
        name   = "trailing clear-to-end-of-line code must not leak into ETA"
        line   = "pulling 797b70c4edf8:  97% ▕███████████████████ ▏  44 MB/ 45 MB   22 MB/s      0s[K"
        expect = @{ Percent = 97; Downloaded = "44 MB"; Total = "45 MB"; Speed = "22 MB/s"; Eta = "0s" }
    }
    @{
        name   = "unrelated line (manifest/digest) returns null, not a false match"
        line   = "verifying sha256 digest"
        expect = $null
    }
)

foreach ($c in $cases) {
    $result = ConvertFrom-OllamaPullLine -Line $c.line
    if ($null -eq $c.expect) {
        if ($null -ne $result) {
            Write-Host "FAIL: $($c.name) -> expected null, got $($result | ConvertTo-Json -Compress)" -ForegroundColor Red
            $failures++
        } else {
            Write-Host "PASS: $($c.name)" -ForegroundColor Green
        }
        continue
    }
    $mismatch = $result.Percent -ne $c.expect.Percent -or $result.Downloaded -ne $c.expect.Downloaded -or
        $result.Total -ne $c.expect.Total -or $result.Speed -ne $c.expect.Speed -or $result.Eta -ne $c.expect.Eta
    if ($mismatch) {
        Write-Host "FAIL: $($c.name) -> got $($result | ConvertTo-Json -Compress)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($c.name)" -ForegroundColor Green
    }
}

$pullDef = (Get-Item Function:\Start-ModelAcquisitionPull).Definition
if ($pullDef -match 'Start-Job') {
    Write-Host "FAIL: Start-ModelAcquisitionPull still contains Start-Job" -ForegroundColor Red
    $failures++
} elseif ($pullDef -notmatch 'Start-Process') {
    Write-Host "FAIL: Start-ModelAcquisitionPull does not contain Start-Process" -ForegroundColor Red
    $failures++
} else {
    Write-Host "PASS: Start-ModelAcquisitionPull uses Start-Process, not Start-Job" -ForegroundColor Green
}

$hfDef = (Get-Item Function:\Start-HuggingFaceImport).Definition
if ($hfDef -match 'Start-Job') {
    Write-Host "FAIL: Start-HuggingFaceImport still contains Start-Job" -ForegroundColor Red
    $failures++
} elseif ($hfDef -notmatch 'Start-Process') {
    Write-Host "FAIL: Start-HuggingFaceImport does not contain Start-Process" -ForegroundColor Red
    $failures++
} else {
    Write-Host "PASS: Start-HuggingFaceImport uses Start-Process, not Start-Job" -ForegroundColor Green
}

$detached = Join-Path $ScriptDir "Invoke-DetachedModelPull.ps1"
if (-not (Test-Path $detached)) {
    Write-Host "FAIL: Invoke-DetachedModelPull.ps1 missing" -ForegroundColor Red
    $failures++
} else {
    $detSrc = Get-Content $detached -Raw
    $detOk = ($detSrc -match 'ollama pull') -and ($detSrc -match 'ollama create') -and ($detSrc -match 'model-pull\.json') -and ($detSrc -match 'lastResult')
    if (-not $detOk) {
        Write-Host "FAIL: Invoke-DetachedModelPull.ps1 missing pull/import/state behavior" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: Invoke-DetachedModelPull.ps1 is self-contained pull/import worker" -ForegroundColor Green
    }
}

$acqSrc = Get-Content (Join-Path $ScriptDir "Get-ModelAcquisition.ps1") -Raw
if ($acqSrc -match 'Start-Job') {
    Write-Host "FAIL: Get-ModelAcquisition.ps1 still contains Start-Job" -ForegroundColor Red
    $failures++
} else {
    Write-Host "PASS: Get-ModelAcquisition.ps1 has no Start-Job" -ForegroundColor Green
}

$oldHome = $env:USERPROFILE
$TempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$scratch = Join-Path $TempRoot "airlock-pull-status-$PID"
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch ".ai-platform\state") -Force | Out-Null
    $env:USERPROFILE = $scratch
    if ($null -ne (Get-ModelPullStatus)) {
        Write-Host "FAIL: Get-ModelPullStatus should be null with no state file" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: Get-ModelPullStatus null when no state file" -ForegroundColor Green
    }

    $statePath = Join-Path $scratch ".ai-platform\state\model-pull.json"
    ([ordered]@{ pid = $PID; model = "test:latest"; startedAt = "t"; kind = "ollama-pull" } | ConvertTo-Json -Compress) |
        Set-Content -Path $statePath -Encoding utf8NoBOM
    $live = Get-ModelPullStatus
    if (-not $live -or [int]$live.pid -ne $PID -or $live.model -ne "test:latest") {
        Write-Host "FAIL: Get-ModelPullStatus should return live pid state" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: Get-ModelPullStatus returns live pid" -ForegroundColor Green
    }

    $reuse = Resolve-AirlockInFlightPull -Existing $live -RequestedModel "test:latest"
    if ($reuse.Action -ne 'reuse') {
        Write-Host "FAIL: same-model in-flight pull should reuse, got $($reuse.Action)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: same-model in-flight pull reuses" -ForegroundColor Green
    }
    $refuse = Resolve-AirlockInFlightPull -Existing $live -RequestedModel "other:7b"
    if ($refuse.Action -ne 'refuse') {
        Write-Host "FAIL: different-model in-flight pull should refuse, got $($refuse.Action)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: different-model in-flight pull refuses" -ForegroundColor Green
    }
    $startGate = Resolve-AirlockInFlightPull -Existing $null -RequestedModel "other:7b"
    if ($startGate.Action -ne 'start') {
        Write-Host "FAIL: no in-flight pull should start, got $($startGate.Action)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: no in-flight pull starts" -ForegroundColor Green
    }

    ([ordered]@{ pid = 999999; model = "dead:latest"; startedAt = "t"; kind = "hf-import" } | ConvertTo-Json -Compress) |
        Set-Content -Path $statePath -Encoding utf8NoBOM
    if ($null -ne (Get-ModelPullStatus)) {
        Write-Host "FAIL: Get-ModelPullStatus should be null for dead pid" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: Get-ModelPullStatus null for dead pid" -ForegroundColor Green
    }

    $failedRec = [pscustomobject]@{ pid = 0; model = 'hf-missing'; lastResult = 'FAILED' }
    $fb = Resolve-AirlockFailedPullFallback -Record $failedRec -RequestedModel 'hf-missing' -FallbackModel 'qwen2.5-coder:7b'
    if ($fb.Action -ne 'fallback' -or $fb.Model -ne 'qwen2.5-coder:7b') {
        Write-Host "FAIL: failed pull of requested model should fall back, got $($fb.Action) $($fb.Model)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: failed pull falls back to smallest curated" -ForegroundColor Green
    }
    $noFb = Resolve-AirlockFailedPullFallback -Record $failedRec -RequestedModel 'other' -FallbackModel 'qwen2.5-coder:7b'
    if ($noFb.Action -ne 'none') {
        Write-Host "FAIL: failed record for a different model should not fall back this request" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: failed record does not steal a different model request" -ForegroundColor Green
    }
    $giveUp = Resolve-AirlockFailedPullFallback -Record ([pscustomobject]@{ pid = 0; model = 'qwen2.5-coder:7b'; lastResult = 'FAILED' }) -RequestedModel 'qwen2.5-coder:7b' -FallbackModel 'qwen2.5-coder:7b'
    if ($giveUp.Action -ne 'give-up') {
        Write-Host "FAIL: failed pull of the fallback itself should give-up, not restart, got $($giveUp.Action)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: failed pull of the fallback model gives up instead of looping" -ForegroundColor Green
    }
} finally {
    $env:USERPROFILE = $oldHome
    if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures -gt 0) { exit 1 }
Write-Host ""
Write-Host "All pull-progress checks passed" -ForegroundColor Green
