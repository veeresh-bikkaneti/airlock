# Self-check for Invoke-OpenCodeCapabilityContract.ps1 (ADR-012 Phase B, §7.3).
# Covers config content shape and config-transaction correlation via a
# mocked Run - does NOT cover a real `opencode run` invocation, which
# requires a live OpenCode CLI and validated endpoint (§10.2).
# Run: pwsh -File scripts/Test-OpenCodeCapabilityContract.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "Invoke-OpenCodeCapabilityContract.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing Invoke-OpenCodeCapabilityContract.ps1..." -ForegroundColor Cyan

# --- Get-OpenCodeStagedConfigContent ---

$sessionId = [guid]::NewGuid().ToString()
$content = Get-OpenCodeStagedConfigContent -ModelRef "gemma4:12b" -EndpointUrl "http://127.0.0.1:12345/v1" -SessionId $sessionId
$parsed = $content | ConvertFrom-Json
Assert-True ($parsed.model -eq "gemma4:12b") "staged config carries the exact model ref"
Assert-True ($parsed.provider.baseUrl -eq "http://127.0.0.1:12345/v1") "staged config carries the exact endpoint URL"
Assert-True ($parsed.airlockSessionId -eq $sessionId) "staged config embeds the session id for correlation (§8.1)"

# --- Invoke-AirlockOpenCodeCapabilityContract: config transaction correlation via a mocked Run ---
# Function -Run injection isn't exposed on Invoke-AirlockOpenCodeCapabilityContract
# itself (it always drives the real workspace contract), so this proves the
# lower-level plumbing it depends on - Invoke-AirlockHarnessConfigTransaction
# now returns whatever -Run produces (RunOutput) - which is the exact fix
# that makes this wrapper's `return $txnResult.RunOutput` correct.

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-opencode-contract-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $configPath = Join-Path $workDir "opencode.json"
    $lockPath = Join-Path $workDir "lock" "opencode.lock"
    $backupDir = Join-Path $workDir "backups"
    $txnDir = Join-Path $workDir "transactions"

    $result = Invoke-AirlockHarnessConfigTransaction -ConfigPath $configPath -StagedContent '{"staged":true}' `
        -LockPath $lockPath -BackupDir $backupDir -TransactionDir $txnDir `
        -Run { return [pscustomobject]@{ Passed = $true; Marker = "fake-contract-result" } }

    Assert-True ($result.RunOutput.Passed) "Invoke-AirlockHarnessConfigTransaction now returns what -Run produced"
    Assert-True ($result.RunOutput.Marker -eq "fake-contract-result") "the returned value is exactly what -Run returned, not a partial/stale copy"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures Invoke-OpenCodeCapabilityContract check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All Invoke-OpenCodeCapabilityContract checks passed" -ForegroundColor Green
