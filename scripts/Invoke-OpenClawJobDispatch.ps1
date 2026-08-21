# Invoke-OpenClawJobDispatch.ps1 — ADR-012 §9.3 "OpenClaw coordinator adapter" (Phase G)
# OpenClaw is optional and never the default execution plane (§9.3). This
# script is the ONLY thing OpenClaw's local coordinator talks to: given a
# requesting operator/channel and a job-template id, it validates both
# against source-controlled config (config/openclaw-job-templates.json -
# never a caller-supplied allowlist/template, so a request cannot smuggle in
# an ad-hoc task/allowedCommands), resolves the effective model context
# against the measured profile context (never a model-card max or a
# high-context tier), builds a job manifest matching
# scripts/agent-job-helpers.ps1's Test-AirlockJobManifestSchema shape, and
# hands off to scripts/Start-AgentWorkerJob.ps1.
#
# This script has NO file-write/shell/secret/git-remote/worker-container
# privilege of its own: the only file it writes is the job manifest itself
# (via the shared Write-AirlockAtomicJson primitive), and all worktree/Docker
# work happens inside Start-AgentWorkerJob.ps1, reused unmodified.
#
# LIVE-HARDWARE GATE: this requires a live capability-registry entry (a real
# passing contract) and, once dispatched, the same live Docker daemon
# Start-AgentWorkerJob.ps1 needs. Not exercised end-to-end in this
# environment - see the implementer's report for exactly what is and is not
# proven here.
param(
    [Parameter(Mandatory)][string]$OperatorId,
    [Parameter(Mandatory)][string]$JobTemplateId,
    [Parameter(Mandatory)][string]$ProfileEvidenceKey,
    [Parameter(Mandatory)][string]$RepoPath,
    [string]$RepoRef = "main",
    [int]$RequestedContext = 4096,
    [string]$JobId,
    [string]$TemplatesConfigPath,
    [string]$PlatformDir = "$env:USERPROFILE\.ai-platform",
    [string]$ContainerImage = "airlock-worker:latest",
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by any of these dot-sourced files reassigning the same variable name.
. (Join-Path $PSScriptRoot "agent-state-helpers.ps1")
. (Join-Path $PSScriptRoot "agent-job-helpers.ps1")
. (Join-Path $PSScriptRoot "agent-openclaw-helpers.ps1")
. (Join-Path $PSScriptRoot "agent-capability-registry.ps1")

if (-not $TemplatesConfigPath) { $TemplatesConfigPath = Join-Path $PSScriptRoot ".." "config" "openclaw-job-templates.json" }
if (-not $JobId) { $JobId = [guid]::NewGuid().ToString() }
$RegistryPath = Join-Path $PlatformDir "state" "capability-registry.json"
$ManifestPath = Join-Path $PlatformDir "state" "jobs" "$JobId.json"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  OpenClaw Job Dispatch" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $TemplatesConfigPath)) {
    Write-Host "FAILED: templates config not found at $TemplatesConfigPath" -ForegroundColor Red
    exit 1
}
$templatesConfig = Get-Content $TemplatesConfigPath -Raw | ConvertFrom-Json

# --- §9.3: allowlisted local operator/channel only ---
$operatorDecision = Resolve-AirlockOpenClawOperatorAllowlist -AllowedOperators @($templatesConfig.allowedOperators) -RequestingOperator $OperatorId
if ($operatorDecision.Decision -ne 'Allowed') {
    Write-Host "FAILED: operator/channel denied. $($operatorDecision.Reason)" -ForegroundColor Red
    exit 1
}
Write-Host "Operator '$OperatorId': $($operatorDecision.Decision) - $($operatorDecision.Reason)" -ForegroundColor Green

# --- §9.3: pre-approved job templates only ---
$templateIds = @($templatesConfig.jobTemplates | ForEach-Object { $_.templateId })
$templateDecision = Resolve-AirlockOpenClawJobTemplateGate -ApprovedJobTemplates $templateIds -RequestedJobTemplate $JobTemplateId
if ($templateDecision.Decision -ne 'Allowed') {
    Write-Host "FAILED: job template denied. $($templateDecision.Reason)" -ForegroundColor Red
    exit 1
}
$template = $templatesConfig.jobTemplates | Where-Object { $_.templateId -eq $JobTemplateId } | Select-Object -First 1
Write-Host "Job template '$JobTemplateId': $($templateDecision.Decision) - $($templateDecision.Reason)" -ForegroundColor Green

# --- §9.3: effective context is the measured profile context, never a
# model-card max or a high-context tier. Requires a currently-passing
# capability-registry entry, same evidence source Start-AgentWorkerJob.ps1
# re-checks before it will launch a worker. ---
$evidenceEntry = Get-AirlockCapabilityEntry -EvidenceKey $ProfileEvidenceKey -RegistryPath $RegistryPath
if (-not $evidenceEntry.FromCache -or $evidenceEntry.Entry.verdict -ne 'pass') {
    Write-Host "FAILED: profileEvidenceKey '$ProfileEvidenceKey' is not a fresh, passing entry in $RegistryPath. $($evidenceEntry.Reason)" -ForegroundColor Red
    exit 1
}
$measuredContext = [int]$evidenceEntry.Entry.effectiveContext
$contextDecision = Resolve-AirlockOpenClawContextCeiling -MeasuredProfileContext $measuredContext -RequestedContext $RequestedContext
Write-Host "Context: requested $RequestedContext, measured profile ceiling $measuredContext -> $($contextDecision.Decision), effective $($contextDecision.EffectiveContext). $($contextDecision.Reason)" -ForegroundColor Green

# --- Build the manifest from the approved template only. RepoPath/RepoRef
# are the only caller-supplied fields that reach the manifest; task,
# allowedCommands, network, credentials, budgets, and output policy all come
# from the pre-approved template, never from the OpenClaw request. ---
$manifest = [ordered]@{
    schemaVersion       = 1
    jobId               = $JobId
    profileEvidenceKey  = $ProfileEvidenceKey
    task                = $template.task
    repo                = [ordered]@{ path = $RepoPath; ref = $RepoRef }
    allowedCommands     = @($template.allowedCommands)
    network             = $template.network
    credentials         = $template.credentials
    maxWallClockMinutes = $template.maxWallClockMinutes
    maxToolSteps        = $template.maxToolSteps
    output              = [ordered]@{
        createBranch = $template.output.createBranch
        allowMerge   = $template.output.allowMerge
        allowPush    = $template.output.allowPush
    }
}

# Round-trip through JSON rather than a bare [pscustomobject] cast: casting
# an [ordered] hashtable only converts the top level, leaving nested
# hashtables (repo, output) as OrderedDictionary objects whose
# .PSObject.Properties don't reflect their keys - Test-AirlockJobManifestSchema
# would then misreport every nested field as missing. The round-trip is
# exactly how Start-AgentWorkerJob.ps1 itself reads a manifest off disk, so
# validating against that same shape here is not a divergent code path.
$manifestObj = $manifest | ConvertTo-Json -Depth 10 | ConvertFrom-Json

$schemaCheck = Test-AirlockJobManifestSchema -Manifest $manifestObj
if (-not $schemaCheck.Valid) {
    Write-Host "FAILED: constructed manifest failed schema validation. Missing: $($schemaCheck.MissingFields -join ', ') $($schemaCheck.Error)" -ForegroundColor Red
    exit 1
}

if ($WhatIf) {
    Write-Host "WHATIF: would write manifest to $ManifestPath and dispatch to Start-AgentWorkerJob.ps1 -JobId $JobId -PlatformDir $PlatformDir" -ForegroundColor Cyan
    Write-Host "WHATIF: no manifest written, no worker dispatched." -ForegroundColor Green
    exit 0
}

Write-AirlockAtomicJson -Path $ManifestPath -Data $manifest
Write-Host "Manifest written to $ManifestPath" -ForegroundColor Green

# --- Hand off to the existing worker-job entry point. This script never
# touches Docker, git, or the worktree directly - Start-AgentWorkerJob.ps1
# re-validates the manifest and evidence key on its own before it launches
# anything. ---
$workerScript = Join-Path $PSScriptRoot "Start-AgentWorkerJob.ps1"
& pwsh -NoProfile -File $workerScript -JobId $JobId -ManifestPath $ManifestPath -PlatformDir $PlatformDir -ContainerImage $ContainerImage
exit $LASTEXITCODE
