# Self-check for Invoke-OpenClawJobDispatch.ps1 (ADR-012 §9.3, Phase G).
# Covers what's testable without a live Docker daemon: operator-denied,
# template-denied, missing/unproven profileEvidenceKey, and the -WhatIf
# no-mutation guarantee (no manifest written, no worker dispatched). The
# live worker handoff is Start-AgentWorkerJob.ps1's own concern and is
# covered by Test-StartAgentWorkerJob.ps1.
# Run: pwsh -File scripts/Test-InvokeOpenClawJobDispatch.ps1
$ErrorActionPreference = "Stop"
$DispatchScript = Join-Path $PSScriptRoot "Invoke-OpenClawJobDispatch.ps1"

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing Invoke-OpenClawJobDispatch.ps1..." -ForegroundColor Cyan

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-openclaw-dispatch-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $platformDir = Join-Path $workDir "platform"
    $repoPath = Join-Path $workDir "repo"
    New-Item -Path $repoPath -ItemType Directory -Force | Out-Null
    $evidenceKey = "sha256:testkey"

    $templatesPath = Join-Path $workDir "openclaw-job-templates.json"
    $templates = [ordered]@{
        schemaVersion    = 1
        allowedOperators = @('local-cli')
        jobTemplates     = @(
            [ordered]@{
                templateId         = 'fixture-smoke-test'
                task                = "Run the repository's existing test command and report pass/fail."
                allowedCommands     = @('pnpm test', 'git status', 'git diff')
                network             = 'disabled'
                credentials         = 'none'
                maxWallClockMinutes = 15
                maxToolSteps        = 20
                output              = [ordered]@{ createBranch = $true; allowMerge = $false; allowPush = $false }
            }
        )
    }
    ($templates | ConvertTo-Json -Depth 10) | Set-Content -Path $templatesPath -Encoding utf8

    function New-PassingRegistry {
        param([string]$Path, [int]$EffectiveContext = 8192)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $registry = [ordered]@{
            schemaVersion = 1
            entries       = [ordered]@{
                "$evidenceKey" = [ordered]@{
                    verdict          = "pass"
                    effectiveContext = $EffectiveContext
                    provenAt         = [DateTime]::UtcNow.ToString('o')
                    expiresAt        = [DateTime]::UtcNow.AddMinutes(30).ToString('o')
                }
            }
        }
        ($registry | ConvertTo-Json -Depth 10) | Set-Content -Path $Path -Encoding utf8
    }

    # --- Operator not allowlisted ---
    & pwsh -NoProfile -File $DispatchScript -OperatorId 'random-slack-bot' -JobTemplateId 'fixture-smoke-test' `
        -ProfileEvidenceKey $evidenceKey -RepoPath $repoPath -TemplatesConfigPath $templatesPath -PlatformDir $platformDir -WhatIf | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) "an operator not on the allowlist is denied and exits non-zero"

    # --- Job template not pre-approved ---
    & pwsh -NoProfile -File $DispatchScript -OperatorId 'local-cli' -JobTemplateId 'deploy-to-prod' `
        -ProfileEvidenceKey $evidenceKey -RepoPath $repoPath -TemplatesConfigPath $templatesPath -PlatformDir $platformDir -WhatIf | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) "a job template that is not pre-approved is denied and exits non-zero"

    # --- Valid operator/template, but no capability-registry entry at all ---
    $noRegistryPlatform = Join-Path $workDir "platform-no-registry"
    & pwsh -NoProfile -File $DispatchScript -OperatorId 'local-cli' -JobTemplateId 'fixture-smoke-test' `
        -ProfileEvidenceKey $evidenceKey -RepoPath $repoPath -TemplatesConfigPath $templatesPath -PlatformDir $noRegistryPlatform -WhatIf | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) "an unproven profileEvidenceKey (no registry entry) is denied and exits non-zero"

    # --- Valid operator/template + fresh passing registry + -WhatIf: zero mutation ---
    $whatIfPlatform = Join-Path $workDir "platform-whatif"
    New-PassingRegistry -Path (Join-Path $whatIfPlatform "state" "capability-registry.json")
    $jobId = [guid]::NewGuid().ToString()
    & pwsh -NoProfile -File $DispatchScript -OperatorId 'local-cli' -JobTemplateId 'fixture-smoke-test' `
        -ProfileEvidenceKey $evidenceKey -RepoPath $repoPath -JobId $jobId `
        -TemplatesConfigPath $templatesPath -PlatformDir $whatIfPlatform -WhatIf | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "-WhatIf with an allowlisted operator, approved template, and passing evidence key exits 0"
    Assert-True (-not (Test-Path (Join-Path $whatIfPlatform "state" "jobs" "$jobId.json"))) "-WhatIf writes no job manifest"
    Assert-True (-not (Test-Path (Join-Path $whatIfPlatform "jobs" $jobId))) "-WhatIf never reaches Start-AgentWorkerJob.ps1 - no job directory at all"

    # --- Real (non-WhatIf) dispatch: manifest is actually written and
    # matches the pre-approved template's fixed fields, not anything the
    # caller could have smuggled in (there is no -Task or -AllowedCommands
    # parameter on this script at all). ---
    $realPlatform = Join-Path $workDir "platform-real"
    New-PassingRegistry -Path (Join-Path $realPlatform "state" "capability-registry.json")
    $realJobId = [guid]::NewGuid().ToString()
    & pwsh -NoProfile -File $DispatchScript -OperatorId 'local-cli' -JobTemplateId 'fixture-smoke-test' `
        -ProfileEvidenceKey $evidenceKey -RepoPath $repoPath -JobId $realJobId `
        -TemplatesConfigPath $templatesPath -PlatformDir $realPlatform 2>&1 | Out-Null
    $writtenManifestPath = Join-Path $realPlatform "state" "jobs" "$realJobId.json"
    Assert-True (Test-Path $writtenManifestPath) "a real (non-WhatIf) dispatch writes the job manifest"
    if (Test-Path $writtenManifestPath) {
        $writtenManifest = Get-Content $writtenManifestPath -Raw | ConvertFrom-Json
        Assert-True ($writtenManifest.allowedCommands -join ',' -eq 'pnpm test,git status,git diff') "the written manifest's allowedCommands come from the pre-approved template, unmodified"
        Assert-True ($writtenManifest.output.allowMerge -eq $false -and $writtenManifest.output.allowPush -eq $false) "the written manifest's output policy comes from the pre-approved template (no merge/push)"
        Assert-True ($writtenManifest.repo.path -eq $repoPath) "the written manifest's repo.path is the caller-supplied RepoPath"
    }
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures Invoke-OpenClawJobDispatch check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All Invoke-OpenClawJobDispatch checks passed" -ForegroundColor Green
exit 0
