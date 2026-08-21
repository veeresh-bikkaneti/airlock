# Self-check for Start-AgentSession.ps1 (ADR-012 Phase B, §7.1).
# Covers what's testable without a real Ollama/OpenCode install: the
# -WhatIf no-mutation guarantee and the profile-resolution failure path.
# The happy path (real transport contract, certificate publish) requires
# live hardware - §10.2 local live acceptance suite.
# Run: pwsh -File scripts/Test-StartAgentSession.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SessionScript = Join-Path $ScriptDir "Start-AgentSession.ps1"

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing Start-AgentSession.ps1..." -ForegroundColor Cyan

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-start-session-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $platformDir = Join-Path $workDir "platform"
    $cataloguePath = Join-Path $ScriptDir ".." "config" "agent-profiles.json"

    # --- -WhatIf: no mutation at all, even for a profile that would otherwise proceed ---
    & pwsh -NoProfile -File $SessionScript -Profile 'ollama-gemma4-12b' -Harness 'opencode' `
        -PlatformDir $platformDir -ProfileCataloguePath $cataloguePath -WhatIf | Out-Null
    $whatIfExit = $LASTEXITCODE
    Assert-True ($whatIfExit -eq 0) "-WhatIf on a valid profile exits 0"
    Assert-True (-not (Test-Path $platformDir)) "-WhatIf creates no platform state directory at all - no lock, no registry, no certificate"

    # --- -WhatIf on a non-Ollama runtime prints THAT profile's own transport
    # plan, not Ollama's - regression test for a real bug: -WhatIf used to
    # hardcode Resolve-OllamaEndpointMode regardless of the selected
    # profile's runtime, so it printed a plan the real path (which correctly
    # dispatches per-runtime) would never actually attempt. ---
    $llamaCppWhatIfOutput = & pwsh -NoProfile -File $SessionScript -Profile 'llamacpp-qwen38-ud-q3-k-xl' -Harness 'opencode' `
        -PlatformDir $platformDir -ProfileCataloguePath $cataloguePath -WhatIf 2>&1 | Out-String
    Assert-True ($llamaCppWhatIfOutput -match 'openai-direct') "-WhatIf on a llama-server profile prints its own transport candidate (openai-direct)"
    Assert-True ($llamaCppWhatIfOutput -notmatch 'ollama-openai') "-WhatIf on a llama-server profile never prints Ollama's transport candidates"

    # --- Unknown profile: fails cleanly, no lock left behind ---
    & pwsh -NoProfile -File $SessionScript -Profile 'does-not-exist' -Harness 'opencode' `
        -PlatformDir $platformDir -ProfileCataloguePath $cataloguePath | Out-Null
    $badProfileExit = $LASTEXITCODE
    Assert-True ($badProfileExit -ne 0) "requesting an unknown profile exits non-zero"
    Assert-True (-not (Test-Path (Join-Path $platformDir "state" "bootstrap.lock"))) "a profile-resolution failure never leaves a lock file behind (it fails before step 1 acquires one)"
    Assert-True (-not (Test-Path (Join-Path $platformDir "state" "active-agent.json"))) "a profile-resolution failure never creates a certificate"

    # --- No profile requested: never auto-selects, fails cleanly ---
    & pwsh -NoProfile -File $SessionScript -Harness 'opencode' `
        -PlatformDir $platformDir -ProfileCataloguePath $cataloguePath | Out-Null
    $noProfileExit = $LASTEXITCODE
    Assert-True ($noProfileExit -ne 0) "no -Profile given -> fails rather than auto-selecting any catalogued candidate"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures Start-AgentSession check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All Start-AgentSession checks passed" -ForegroundColor Green
exit 0
