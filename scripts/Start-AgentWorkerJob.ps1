# Start-AgentWorkerJob.ps1 — ADR-012 §9 "Job-manifest worker" (Phase F)
# Reads a job manifest (state/jobs/<job-id>.json - "the only input that
# permits an autonomous worker launch", §9.1), validates it, confirms its
# profileEvidenceKey is a current passing entry in the Phase A/B capability
# registry, creates an isolated Git worktree under
# $PlatformDir\jobs\<jobId>\worktree, and launches a locked-down, non-admin,
# ephemeral Docker worker against it (§9.2): only the job worktree writable,
# no Docker socket/host-process/browser-session/secrets/home-directory
# mount, network disabled unless the manifest exactly says "enabled",
# bounded CPU/RAM/wall-clock/tool-steps. Writes an append-only redacted
# JSONL audit trail and a final patch/test summary. Never merges, pushes, or
# performs any action beyond producing an unmerged patch in the worktree,
# regardless of the manifest's output.allowMerge/allowPush values - those
# are recorded for the caller, not acted on here (§9.2, §13).
#
# See scripts/agent-job-helpers.ps1 for the pure decision functions this
# wires together and Test-AgentJobHelpers.ps1 for their unit coverage.
#
# LIVE-HARDWARE GATE: the actual `docker run` launch below requires a live,
# reachable, non-admin-capable Docker daemon. It is real code but is not
# exercised end-to-end in this environment - see the implementer's report
# for exactly what is and is not proven here.
param(
    [Parameter(Mandatory)][string]$JobId,
    [string]$ManifestPath,
    [string]$PlatformDir = "$env:USERPROFILE\.ai-platform",
    [string]$ContainerImage = "airlock-worker:latest",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by any of these dot-sourced files reassigning the same variable name.
. (Join-Path $PSScriptRoot "agent-state-helpers.ps1")
. (Join-Path $PSScriptRoot "agent-job-helpers.ps1")
. (Join-Path $PSScriptRoot "agent-capability-registry.ps1")

if (-not $ManifestPath) { $ManifestPath = Join-Path $PlatformDir "state" "jobs" "$JobId.json" }
$JobDir = Join-Path $PlatformDir "jobs" $JobId
$WorktreePath = Join-Path $JobDir "worktree"
$PolicyFilePath = Join-Path $JobDir "job-policy.json"
$AuditLogPath = Join-Path $JobDir "audit.jsonl"
$ResultPath = Join-Path $JobDir "result.json"
$RegistryPath = Join-Path $PlatformDir "state" "capability-registry.json"

# Append-only, redacted: never writes the manifest's task text, repo path,
# or any credential/env value - only IDs, decisions, and bounded diagnostic
# strings. No-op under -WhatIf so the discovery-only path creates nothing.
function Write-JobAuditLog {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('STARTED', 'SUCCESS', 'WARNING', 'FAILED')][string]$Result,
        [string]$Message = "",
        [string]$Detail = ""
    )
    if ($WhatIf) { return }
    if (-not (Test-Path $JobDir)) { New-Item -Path $JobDir -ItemType Directory -Force | Out-Null }
    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        user         = $env:USERNAME
        host         = $env:COMPUTERNAME
        jobId        = $JobId
        action       = $Action
        result       = $Result
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $AuditLogPath -Encoding utf8
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Airlock Agent Worker Job Starting" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $ManifestPath)) {
    Write-Host "FAILED: job manifest not found at $ManifestPath" -ForegroundColor Red
    exit 1
}
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

# --- Refuse to proceed past an invalid manifest (§9.1) ---
$schemaCheck = Test-AirlockJobManifestSchema -Manifest $manifest
if (-not $schemaCheck.Valid) {
    Write-JobAuditLog -Action "ManifestValidate" -Result "FAILED" -Message "Schema validation failed" -Detail (($schemaCheck.MissingFields -join ', ') + ' ' + $schemaCheck.Error)
    Write-Host "FAILED: manifest schema invalid. Missing: $($schemaCheck.MissingFields -join ', ') $($schemaCheck.Error)" -ForegroundColor Red
    exit 1
}
if ($manifest.jobId -ne $JobId) {
    Write-JobAuditLog -Action "ManifestValidate" -Result "FAILED" -Message "jobId mismatch"
    Write-Host "FAILED: manifest jobId '$($manifest.jobId)' does not match requested JobId '$JobId'." -ForegroundColor Red
    exit 1
}
Write-JobAuditLog -Action "ManifestValidate" -Result "SUCCESS" -Message "Manifest passed schema validation"

# --- profileEvidenceKey must be a currently-passing verdict in the Phase
# A/B capability registry - a schema-valid manifest referencing an unproven,
# expired, or failed evidence key never launches a worker. ---
$evidenceEntry = Get-AirlockCapabilityEntry -EvidenceKey $manifest.profileEvidenceKey -RegistryPath $RegistryPath
if (-not $evidenceEntry.FromCache -or $evidenceEntry.Entry.verdict -ne 'pass') {
    Write-JobAuditLog -Action "EvidenceKeyCheck" -Result "FAILED" -Message "profileEvidenceKey is not a fresh passing capability verdict" -Detail $evidenceEntry.Reason
    Write-Host "FAILED: profileEvidenceKey '$($manifest.profileEvidenceKey)' is not a fresh, passing entry in $RegistryPath. $($evidenceEntry.Reason)" -ForegroundColor Red
    exit 1
}
Write-JobAuditLog -Action "EvidenceKeyCheck" -Result "SUCCESS" -Message "profileEvidenceKey matches a fresh passing capability verdict"

$networkPolicy = Resolve-AirlockNetworkPolicy -Network $manifest.network
$mergePolicy = Resolve-AirlockJobOutputPolicy -AllowMerge ([bool]$manifest.output.allowMerge) -AllowPush ([bool]$manifest.output.allowPush) -Action 'Merge'
$pushPolicy = Resolve-AirlockJobOutputPolicy -AllowMerge ([bool]$manifest.output.allowMerge) -AllowPush ([bool]$manifest.output.allowPush) -Action 'Push'

if ($WhatIf) {
    Write-Host "WHATIF: manifest at $ManifestPath is schema-valid and profileEvidenceKey is a fresh passing verdict" -ForegroundColor Cyan
    Write-Host "WHATIF: would create a detached worktree at $WorktreePath for $($manifest.repo.path)@$($manifest.repo.ref)" -ForegroundColor Cyan
    Write-Host "WHATIF: network = $($networkPolicy.Decision); merge = $($mergePolicy.Decision); push = $($pushPolicy.Decision)" -ForegroundColor Cyan
    Write-Host "WHATIF: would launch docker image '$ContainerImage' bounded to $($manifest.maxWallClockMinutes)min / $($manifest.maxToolSteps) tool steps" -ForegroundColor Cyan
    Write-Host "WHATIF: no worktree created, no container started, no audit log or result written." -ForegroundColor Green
    exit 0
}

# --- Create the isolated worktree (§9.2) ---
if (Test-Path $JobDir) {
    Write-Host "FAILED: job directory already exists at $JobDir - refusing to reuse a jobId. Use a fresh jobId." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $manifest.repo.path)) {
    Write-JobAuditLog -Action "WorktreeCreate" -Result "FAILED" -Message "Repo path not found"
    Write-Host "FAILED: repo path '$($manifest.repo.path)' does not exist." -ForegroundColor Red
    exit 1
}

Write-JobAuditLog -Action "WorktreeCreate" -Result "STARTED" -Message "Creating detached worktree" -Detail $manifest.repo.ref
$worktreeOutput = & git -C $manifest.repo.path worktree add --detach $WorktreePath $manifest.repo.ref 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-JobAuditLog -Action "WorktreeCreate" -Result "FAILED" -Message "git worktree add failed" -Detail ($worktreeOutput | Out-String).Trim()
    Write-Host "FAILED: git worktree add failed for ref '$($manifest.repo.ref)'." -ForegroundColor Red
    exit 1
}
Write-JobAuditLog -Action "WorktreeCreate" -Result "SUCCESS" -Message "Worktree created" -Detail $WorktreePath

$workerBranch = $null
if ($manifest.output.createBranch) {
    $workerBranch = "airlock-job-$JobId"
    $branchOutput = & git -C $WorktreePath checkout -b $workerBranch 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-JobAuditLog -Action "BranchCreate" -Result "FAILED" -Message "git checkout -b failed" -Detail ($branchOutput | Out-String).Trim()
        Write-Host "FAILED: could not create branch '$workerBranch' in the job worktree." -ForegroundColor Red
        & git -C $manifest.repo.path worktree remove --force $WorktreePath 2>&1 | Out-Null
        exit 1
    }
    Write-JobAuditLog -Action "BranchCreate" -Result "SUCCESS" -Message "Created worker branch" -Detail $workerBranch
}

# --- Stage the read-only in-container tool policy (allowlist + network +
# credentials mode + bounds) that Build-AirlockWorkerDockerArgs mounts. ---
$policyData = [ordered]@{
    schemaVersion       = 1
    jobId               = $JobId
    allowedCommands     = @($manifest.allowedCommands)
    network             = $networkPolicy.Decision
    credentials         = $manifest.credentials
    maxWallClockMinutes = $manifest.maxWallClockMinutes
    maxToolSteps        = $manifest.maxToolSteps
}
Write-AirlockAtomicJson -Path $PolicyFilePath -Data $policyData

# --- Construct the locked-down Docker launch (§9.2) ---
$containerName = "airlock-job-$JobId"
$dockerArgs = Build-AirlockWorkerDockerArgs -JobWorktreePath $WorktreePath -PolicyFilePath $PolicyFilePath `
    -ContainerImage $ContainerImage -NetworkDecision $networkPolicy.Decision `
    -MaxWallClockMinutes $manifest.maxWallClockMinutes -MaxToolSteps $manifest.maxToolSteps -ContainerName $containerName

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-JobAuditLog -Action "WorkerLaunch" -Result "FAILED" -Message "docker not found on PATH"
    Write-Host "FAILED: docker not found on PATH. Cannot launch the sandboxed worker." -ForegroundColor Red
    exit 1
}

Write-JobAuditLog -Action "WorkerLaunch" -Result "STARTED" -Message "Launching worker container" -Detail $containerName
Write-Host "Launching sandboxed worker container '$containerName' (image: $ContainerImage)..." -ForegroundColor Yellow
$proc = Start-Process -FilePath 'docker' -ArgumentList $dockerArgs -WorkingDirectory $WorktreePath -WindowStyle Hidden -PassThru

# Wall-clock bound enforced here (Docker has no native run-duration timeout):
# wait up to maxWallClockMinutes, then kill the container and the docker CLI
# process on the host if it hasn't exited on its own.
$wallClockMs = [int]$manifest.maxWallClockMinutes * 60 * 1000
$exited = $proc.WaitForExit($wallClockMs)
if (-not $exited) {
    Write-Host "  Wall-clock budget ($($manifest.maxWallClockMinutes)min) exceeded - killing worker container." -ForegroundColor Yellow
    & docker kill $containerName 2>&1 | Out-Null
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    $workerExitCode = $null
    $workerFailed = $true
    Write-JobAuditLog -Action "WorkerLaunch" -Result "FAILED" -Message "Wall-clock budget exceeded" -Detail "$($manifest.maxWallClockMinutes)min"
} else {
    $workerExitCode = $proc.ExitCode
    $workerFailed = ($workerExitCode -ne 0)
    Write-JobAuditLog -Action "WorkerLaunch" -Result $(if ($workerFailed) { "FAILED" } else { "SUCCESS" }) -Message "Worker container exited" -Detail "exit $workerExitCode"
}

# --- Final patch/test summary (§9.2, §13: "produces only an unmerged
# patch"). This script never merges or pushes, regardless of the manifest's
# output.allowMerge/allowPush - those are recorded for the caller only. ---
$diffStat = (& git -C $WorktreePath diff --stat 2>&1 | Out-String).Trim()
$statusPorcelain = (& git -C $WorktreePath status --porcelain 2>&1 | Out-String).Trim()

$summary = [ordered]@{
    schemaVersion      = 1
    jobId              = $JobId
    worktreePath       = $WorktreePath
    workerBranch       = $workerBranch
    workerExitCode     = $workerExitCode
    wallClockExceeded  = (-not $exited)
    diffStat           = $diffStat
    hasChanges         = [bool]$statusPorcelain
    outputPolicy       = [ordered]@{ merge = $mergePolicy.Decision; push = $pushPolicy.Decision }
    completedAtUtc     = [DateTime]::UtcNow.ToString('o')
    note               = "Unmerged, unpushed patch in the job worktree. This script never merges or pushes on its own, regardless of the output policy decisions above."
}
Write-AirlockAtomicJson -Path $ResultPath -Data $summary
Write-JobAuditLog -Action "JobComplete" -Result $(if ($workerFailed) { "FAILED" } else { "SUCCESS" }) -Message "Result summary written" -Detail $ResultPath

if ($workerFailed) {
    Write-Host "FAILED: worker job did not complete successfully. See $ResultPath and $AuditLogPath." -ForegroundColor Red
    exit 1
}
Write-Host "SUCCESS: worker job completed. Unmerged, unpushed patch is available at $WorktreePath." -ForegroundColor Green
exit 0
