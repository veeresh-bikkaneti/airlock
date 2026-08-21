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
# Shape confirmed via `opencode debug config` against a real install (BUG
# FOUND BY A LIVE RUN: the original flat {model, provider:{baseUrl}} shape
# was never checked against opencode's real schema - see the fix's comment
# in Get-OpenCodeStagedConfigContent for the full story).
Assert-True ($parsed.model -eq "airlock/gemma4:12b") "staged config's top-level model is '<providerId>/<modelRef>', matching the CLI's own -m format"
Assert-True ($parsed.provider.airlock.npm -eq "@ai-sdk/openai-compatible") "staged config declares the openai-compatible adapter opencode needs for a custom endpoint"
Assert-True ($parsed.provider.airlock.options.baseURL -eq "http://127.0.0.1:12345/v1") "staged config carries the exact endpoint URL under options.baseURL (capital URL, real key name)"
Assert-True ($parsed.provider.airlock.models.'gemma4:12b'.name -eq "gemma4:12b") "staged config declares the exact model ref under provider.models"
Assert-True ($parsed.provider.airlock.options.apiKey -eq "airlock-session-$sessionId") "staged config embeds the session id in the free-text apiKey for correlation (§8.1) - opencode's schema has no room for an arbitrary top-level field"

# --- Test-AirlockOpenCodeRawToolEventInStdout ---
# BUG FOUND BY A LIVE RUN: qwen2.5-coder:7b prints raw {"name": "write",
# "arguments": {...}} lines to plain stdout instead of issuing a real tool
# call - the original regex only matched {"action"/{"tool_call(s)" and missed
# this real, observed shape entirely.
Assert-True (Test-AirlockOpenCodeRawToolEventInStdout -Stdout '{"name": "write", "arguments": {"content": "DONE", "filePath": "output.md"}}') "a raw {`"name`": ...} line is detected as a fallback tool event, not a real one"
Assert-True (Test-AirlockOpenCodeRawToolEventInStdout -Stdout '{"action": "write"}') "the original {`"action`"...} shape is still detected"
Assert-True (-not (Test-AirlockOpenCodeRawToolEventInStdout -Stdout "I've created output.md with the requested content. DONE")) "normal prose output is not flagged as a fallback tool event"

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
exit 0
