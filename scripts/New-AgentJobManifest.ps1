# New-AgentJobManifest.ps1 — the landing bridge for the Pi-first coding door.
#
# ai-agent-start proves the capability on this hardware and publishes
# state/active-agent.json. Start-AgentWorkerJob runs the agent, but it demands
# a hand-written job manifest whose profileEvidenceKey is a capability-registry
# hash - nothing authored that manifest for the user, so the proven pipeline
# dead-ended at the certificate. This script closes the gap: it reads the live
# certificate, re-verifies a fresh passing registry entry, and authors a
# schema-valid manifest with secure defaults. The user supplies only the task
# and the repo; the script prints the exact launch command.
#
# Usage:
#   .\scripts\New-AgentJobManifest.ps1 -Task "Fix the failing Test-Foo suite" -RepoPath "C:\source\project"
#   .\scripts\Start-AgentWorkerJob.ps1 -JobId <printed-id>
param(
    [Parameter(Mandatory)][string]$Task,
    [Parameter(Mandatory)][string]$RepoPath,
    [string]$Ref = 'HEAD',
    [string[]]$AllowedCommands = @('git', 'pwsh', 'python'),
    [ValidateSet('disabled', 'enabled')][string]$Network = 'disabled',
    [int]$MaxWallClockMinutes = 60,
    [int]$MaxToolSteps = 40,
    [switch]$AllowMerge,
    [switch]$AllowPush,
    [string]$JobId = '',
    [string]$PlatformDir = "$env:USERPROFILE\.ai-platform"
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by a dot-sourced file elsewhere in the chain reassigning the same variable name.
. (Join-Path $PSScriptRoot 'agent-state-helpers.ps1')
. (Join-Path $PSScriptRoot 'agent-capability-registry.ps1')
. (Join-Path $PSScriptRoot 'agent-job-helpers.ps1')
. (Join-Path $PSScriptRoot 'session-resume.ps1')

$CertificatePath = Join-Path $PlatformDir 'state' 'active-agent.json'
$RegistryPath = Join-Path $PlatformDir 'state' 'capability-registry.json'

# --- 1. live certificate, Pi-compatible ---
$certificate = $null
if (Test-Path $CertificatePath) {
    try { $certificate = Get-Content $CertificatePath -Raw | ConvertFrom-Json } catch { $certificate = $null }
}
$certValidity = Resolve-AirlockCertificateValidity -Certificate $certificate `
    -Now ([DateTime]::UtcNow) -CompatibleHarnesses @('pi-worker')
if (-not $certValidity.Valid) {
    Write-Host "FAILED: no valid Pi-compatible agent certificate ($($certValidity.Reason)). $($certValidity.Detail)" -ForegroundColor Red
    Write-Host '  Run ai-agent-start -Harness pi-worker first.' -ForegroundColor Yellow
    exit 1
}

# --- 2. the certificate's evidence key must be a FRESH passing registry entry ---
# Start-AgentWorkerJob re-checks this at launch; authoring against a stale key
# would hand the user a manifest that fails its first gate.
$evidenceKey = [string]$certificate.capabilityEvidenceKey
if (-not $evidenceKey) {
    Write-Host 'FAILED: active-agent.json has no capabilityEvidenceKey.' -ForegroundColor Red
    exit 1
}
$evidenceEntry = Get-AirlockCapabilityEntry -EvidenceKey $evidenceKey -RegistryPath $RegistryPath
if (-not $evidenceEntry.FromCache -or $evidenceEntry.Entry.verdict -ne 'pass') {
    Write-Host "FAILED: evidence key is not a fresh passing verdict ($($evidenceEntry.Reason))." -ForegroundColor Red
    Write-Host '  Re-run ai-agent-start -Harness pi-worker - the pass TTL is 5 minutes.' -ForegroundColor Yellow
    exit 1
}

# --- 3. repo must exist and be a git repo (the worker builds a worktree) ---
if (-not (Test-Path $RepoPath)) {
    Write-Host "FAILED: repo path not found: $RepoPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    Write-Host "FAILED: $RepoPath is not a git repo - the worker job builds an isolated git worktree." -ForegroundColor Red
    exit 1
}

# Existing task string only. No new manifest fields. Absent snapshot -> unchanged.
$sessionStatePath = Join-Path (Join-Path $RepoPath '.ai-context') 'SESSION_STATE.md'
if (Test-Path -LiteralPath $sessionStatePath) {
    $sessionText = Get-Content -LiteralPath $sessionStatePath -Raw
    $Task = Resolve-AirlockWorkerTaskText -Task $Task -SessionText $sessionText
}

# --- 4. author the manifest with secure defaults ---
if (-not $JobId) { $JobId = [guid]::NewGuid().ToString('N').Substring(0, 8) }
$manifest = [ordered]@{
    schemaVersion       = 1
    jobId               = $JobId
    profileEvidenceKey  = $evidenceKey
    task                = $Task
    repo                = [ordered]@{ path = $RepoPath; ref = $Ref }
    allowedCommands     = @($AllowedCommands)
    network             = $Network
    credentials         = 'none'
    maxWallClockMinutes = $MaxWallClockMinutes
    maxToolSteps        = $MaxToolSteps
    output              = [ordered]@{
        createBranch = $true
        # Intent declarations only - Start-AgentWorkerJob never merges or
        # pushes regardless; those gates belong to the caller, per §9.2/§13.
        allowMerge   = [bool]$AllowMerge
        allowPush    = [bool]$AllowPush
    }
}

# Self-check: never hand the user a manifest that fails the worker's own gate.
$schemaCheck = Test-AirlockJobManifestSchema -Manifest ([pscustomobject]$manifest)
if (-not $schemaCheck.Valid) {
    Write-Host "FAILED: authored manifest failed schema validation: $($schemaCheck.MissingFields -join ', ') $($schemaCheck.Error)" -ForegroundColor Red
    exit 1
}

$jobsDir = Join-Path $PlatformDir 'state' 'jobs'
if (-not (Test-Path $jobsDir)) { New-Item -Path $jobsDir -ItemType Directory -Force | Out-Null }
$manifestPath = Join-Path $jobsDir "$JobId.json"
Write-AirlockAtomicJson -Path $manifestPath -Data $manifest

Write-Host ''
Write-Host 'MANIFEST READY' -ForegroundColor Green
Write-Host "  job:      $JobId"
Write-Host "  manifest: $manifestPath"
Write-Host "  evidence: fresh passing verdict for '$($certificate.model)' via $($certificate.transport.mode)"
Write-Host "  bounds:   network=$Network, ${MaxWallClockMinutes}min, ${MaxToolSteps} tool steps, merge=$([bool]$AllowMerge), push=$([bool]$AllowPush)"
Write-Host ''
Write-Host 'Launch it:' -ForegroundColor Cyan
Write-Host "  .\scripts\Start-AgentWorkerJob.ps1 -JobId $JobId" -ForegroundColor White
Write-Host '  (launch before the evidence pass TTL expires - about 5 minutes - or re-run ai-agent-start)' -ForegroundColor Yellow
