# Self-check for Start-AgentWorkerJob.ps1 (ADR-012 §9.2, Phase F).
# Covers what's testable without a real Docker daemon: manifest-not-found,
# schema-invalid manifest, jobId mismatch, an unproven profileEvidenceKey,
# and the -WhatIf no-mutation guarantee. The live worker launch (real
# `docker run`, real worktree contents) requires live Docker - not exercised
# here, see the implementer's report.
# Run: pwsh -File scripts/Test-StartAgentWorkerJob.ps1
$ErrorActionPreference = "Stop"
$JobScript = Join-Path $PSScriptRoot "Start-AgentWorkerJob.ps1"

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing Start-AgentWorkerJob.ps1..." -ForegroundColor Cyan

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-worker-job-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $platformDir = Join-Path $workDir "platform"
    $jobId = [guid]::NewGuid().ToString()
    $evidenceKey = "sha256:testkey"

    function New-ManifestFile {
        param([string]$Path, [hashtable]$Overrides = @{})
        $manifest = [ordered]@{
            schemaVersion       = 1
            jobId               = $jobId
            profileEvidenceKey  = $evidenceKey
            task                = "Implement the approved issue in the worktree and run the listed tests."
            repo                = [ordered]@{ path = (Join-Path $workDir "repo"); ref = "main" }
            allowedCommands     = @("pnpm test", "pnpm lint", "git diff", "git status")
            network             = "disabled"
            credentials         = "none"
            maxWallClockMinutes = 45
            maxToolSteps        = 80
            output              = [ordered]@{ createBranch = $true; allowMerge = $false; allowPush = $false }
        }
        foreach ($k in $Overrides.Keys) { $manifest[$k] = $Overrides[$k] }
        ($manifest | ConvertTo-Json -Depth 10) | Set-Content -Path $Path -Encoding utf8
    }

    function New-PassingRegistry {
        param([string]$Path)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $registry = [ordered]@{
            schemaVersion = 1
            entries       = [ordered]@{
                "$evidenceKey" = [ordered]@{
                    verdict   = "pass"
                    provenAt  = [DateTime]::UtcNow.ToString('o')
                    expiresAt = [DateTime]::UtcNow.AddMinutes(30).ToString('o')
                }
            }
        }
        ($registry | ConvertTo-Json -Depth 10) | Set-Content -Path $Path -Encoding utf8
    }

    # --- Manifest not found ---
    $missingManifestPath = Join-Path $workDir "does-not-exist.json"
    & pwsh -NoProfile -File $JobScript -JobId $jobId -ManifestPath $missingManifestPath -PlatformDir $platformDir | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) "a missing manifest file exits non-zero"

    # --- Schema-invalid manifest (missing maxWallClockMinutes) ---
    $badManifestPath = Join-Path $workDir "bad-manifest.json"
    $badManifest = [ordered]@{
        schemaVersion = 1; jobId = $jobId; profileEvidenceKey = $evidenceKey; task = "x"
        repo = [ordered]@{ path = "C:\x"; ref = "main" }; allowedCommands = @("git status")
        network = "disabled"; credentials = "none"; maxToolSteps = 80
        output = [ordered]@{ createBranch = $true; allowMerge = $false; allowPush = $false }
    }
    ($badManifest | ConvertTo-Json -Depth 10) | Set-Content -Path $badManifestPath -Encoding utf8
    & pwsh -NoProfile -File $JobScript -JobId $jobId -ManifestPath $badManifestPath -PlatformDir $platformDir | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) "a schema-invalid manifest (missing maxWallClockMinutes) exits non-zero"
    Assert-True (-not (Test-Path (Join-Path $platformDir "jobs" $jobId "worktree"))) "a schema-invalid manifest never creates a worktree"

    # --- jobId mismatch ---
    $mismatchPath = Join-Path $workDir "mismatch-manifest.json"
    New-ManifestFile -Path $mismatchPath -Overrides @{ jobId = [guid]::NewGuid().ToString() }
    & pwsh -NoProfile -File $JobScript -JobId $jobId -ManifestPath $mismatchPath -PlatformDir $platformDir | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) "a manifest whose jobId does not match the requested JobId exits non-zero"

    # --- Valid manifest, but no capability registry entry at all ---
    $validManifestPath = Join-Path $workDir "valid-manifest.json"
    New-ManifestFile -Path $validManifestPath
    $noRegistryPlatform = Join-Path $workDir "platform-no-registry"
    & pwsh -NoProfile -File $JobScript -JobId $jobId -ManifestPath $validManifestPath -PlatformDir $noRegistryPlatform | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) "a schema-valid manifest with no matching capability-registry entry exits non-zero (evidence key not proven)"
    Assert-True (-not (Test-Path (Join-Path $noRegistryPlatform "jobs" $jobId "worktree"))) "an unproven profileEvidenceKey never creates a worktree"

    # --- Valid manifest + fresh passing registry entry + -WhatIf: zero mutation ---
    $whatIfPlatform = Join-Path $workDir "platform-whatif"
    New-PassingRegistry -Path (Join-Path $whatIfPlatform "state" "capability-registry.json")
    & pwsh -NoProfile -File $JobScript -JobId $jobId -ManifestPath $validManifestPath -PlatformDir $whatIfPlatform -WhatIf | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "-WhatIf on a schema-valid manifest with a passing evidence key exits 0"
    Assert-True (-not (Test-Path (Join-Path $whatIfPlatform "jobs" $jobId))) "-WhatIf creates no job directory at all - no worktree, no audit log, no result"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures Start-AgentWorkerJob check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All Start-AgentWorkerJob checks passed" -ForegroundColor Green
exit 0
