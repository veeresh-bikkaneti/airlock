# agent-job-helpers.ps1 — ADR-012 §9 "Job-manifest worker" (Phase F)
# Pure decision functions for the job-manifest launch path: manifest schema
# validation, the command allowlist, and the network/output policy gates.
# Same convention as agent-profile-helpers.ps1/agent-state-helpers.ps1 - no
# runtime/Docker/git I/O here, so every rule is testable without a live
# Docker daemon. See Test-AgentJobHelpers.ps1 and
# scripts/Start-AgentWorkerJob.ps1 (the orchestrator that wires these into
# real worktree/Docker/audit-log I/O).

$RequiredJobManifestFields = @(
    'schemaVersion', 'jobId', 'profileEvidenceKey', 'task', 'repo', 'allowedCommands',
    'network', 'credentials', 'maxWallClockMinutes', 'maxToolSteps', 'output'
)
$RequiredJobManifestRepoFields = @('path', 'ref')
$RequiredJobManifestOutputFields = @('createBranch', 'allowMerge', 'allowPush')

# §9.1: "state/jobs/<job-id>.json is the only input that permits an
# autonomous worker launch." Validates shape only, following the same
# pattern as Test-AirlockProfileSchema - a schema-valid manifest is not
# itself an authorization to merge/push/enable network, see
# Resolve-AirlockJobOutputPolicy / Resolve-AirlockNetworkPolicy for those.
function Test-AirlockJobManifestSchema {
    param([Parameter(Mandatory)]$Manifest)

    $missing = @($RequiredJobManifestFields | Where-Object { -not ($Manifest.PSObject.Properties.Name -contains $_) })
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{ Valid = $false; MissingFields = $missing }
    }

    $missingNested = @()
    if ($Manifest.repo) {
        $missingNested += @($RequiredJobManifestRepoFields | Where-Object { -not ($Manifest.repo.PSObject.Properties.Name -contains $_) }) | ForEach-Object { "repo.$_" }
    } else {
        $missingNested += $RequiredJobManifestRepoFields | ForEach-Object { "repo.$_" }
    }
    if ($Manifest.output) {
        $missingNested += @($RequiredJobManifestOutputFields | Where-Object { -not ($Manifest.output.PSObject.Properties.Name -contains $_) }) | ForEach-Object { "output.$_" }
    } else {
        $missingNested += $RequiredJobManifestOutputFields | ForEach-Object { "output.$_" }
    }
    if ($missingNested.Count -gt 0) {
        return [pscustomobject]@{ Valid = $false; MissingFields = $missingNested }
    }

    if (-not $Manifest.allowedCommands -or @($Manifest.allowedCommands).Count -eq 0) {
        return [pscustomobject]@{ Valid = $false; MissingFields = @(); Error = "allowedCommands must be a non-empty list - an empty allowlist is not a valid launch input." }
    }

    return [pscustomobject]@{ Valid = $true; MissingFields = @() }
}

# §10.1 "command allowlist" / "denied escape attempts". Exact-match only,
# NEVER prefix/substring/partial. A requested command that starts with,
# extends, or otherwise contains an allowed entry (shell chaining like
# "pnpm test; rm -rf /", "pnpm test && curl evil.com", "pnpm test | sh", or
# any superstring of an allowed command) must be Denied - matching on
# anything less than full string equality would let exactly those escapes
# through. Comparison is case-sensitive (-ccontains): an allowlist is a
# literal command list, not a case-insensitive display string, and being
# stricter here never denies a legitimate exact entry the manifest actually
# lists.
function Resolve-AirlockCommandAllowlist {
    param(
        [Parameter(Mandatory)][string[]]$AllowedCommands,
        [Parameter(Mandatory)][string]$RequestedCommand
    )
    if ($AllowedCommands -ccontains $RequestedCommand) {
        return [pscustomobject]@{ Decision = 'Allowed'; Reason = "Exact (case-sensitive) match against the manifest's allowedCommands." }
    }
    return [pscustomobject]@{ Decision = 'Denied'; Reason = "No exact match in allowedCommands. Prefix, substring, superstring, and shell-chained/piped variants of an allowed command are never treated as allowed." }
}

# §9.2: "cannot merge, push, deploy... without a newly approved job
# manifest." Default posture is DENY. Even output.allowMerge/allowPush=true
# in THIS manifest is read narrowly, as this job's declared intent only -
# not as proof that a separate approval gate (human review, CI) has actually
# authorized the merge/push. Callers must not treat an "Allowed" verdict
# here as sufficient on its own to perform the action; it only means this
# manifest did not forbid it.
function Resolve-AirlockJobOutputPolicy {
    param(
        [Parameter(Mandatory)][bool]$AllowMerge,
        [Parameter(Mandatory)][bool]$AllowPush,
        [Parameter(Mandatory)][ValidateSet('Merge', 'Push')][string]$Action
    )
    $flag = if ($Action -eq 'Merge') { $AllowMerge } else { $AllowPush }
    if (-not $flag) {
        return [pscustomobject]@{ Decision = 'Denied'; Reason = "output.allow$Action is false or absent - default posture denies $Action." }
    }
    return [pscustomobject]@{
        Decision = 'Allowed'
        Reason   = "output.allow$Action is explicitly true in this manifest. This reflects only this job's declared intent - it is not itself proof of a separate, already-granted $Action approval, and a caller must still enforce that gate before actually performing $Action."
    }
}

# Network default posture is disabled. Only the exact literal "enabled"
# (case-sensitive) turns it on; "disabled", empty, unset, or any typo/other
# value all fail closed to disabled - matches §9.1's example manifest, whose
# only shown value is "disabled".
function Resolve-AirlockNetworkPolicy {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Network)
    if ($Network -ceq 'enabled') {
        return [pscustomobject]@{ Decision = 'Enabled'; Reason = "network is exactly 'enabled'." }
    }
    return [pscustomobject]@{ Decision = 'Disabled'; Reason = "network is not exactly 'enabled' (got '$Network') - fail-closed default is disabled." }
}

# §9.2 Docker launch-argument construction. Pure string-building - no
# process is started here. Enumerates by omission everything the ADR
# forbids: no --volume for the Docker socket, no --pid=host, no
# --network=host except via the explicit Enabled decision, no browser-
# session/secrets/home-directory mount, no --privileged. Only the job
# worktree (and a read-only policy file) are ever mounted.
function Build-AirlockWorkerDockerArgs {
    param(
        [Parameter(Mandatory)][string]$JobWorktreePath,
        [Parameter(Mandatory)][string]$PolicyFilePath,
        [Parameter(Mandatory)][string]$ContainerImage,
        [Parameter(Mandatory)][ValidateSet('Enabled', 'Disabled')][string]$NetworkDecision,
        [Parameter(Mandatory)][int]$MaxWallClockMinutes,
        [Parameter(Mandatory)][int]$MaxToolSteps,
        [double]$CpuLimit = 2.0,
        [string]$MemoryLimit = "4g",
        [string]$ContainerName
    )
    if ($MaxWallClockMinutes -le 0) { throw "MaxWallClockMinutes must be positive." }
    if ($MaxToolSteps -le 0) { throw "MaxToolSteps must be positive." }

    $dockerArgs = [System.Collections.Generic.List[string]]::new()
    $dockerArgs.Add('run')
    $dockerArgs.Add('--rm')
    if ($ContainerName) { $dockerArgs.Add('--name'); $dockerArgs.Add($ContainerName) }
    # non-admin, ephemeral: no root inside the container, no elevated caps.
    $dockerArgs.Add('--user'); $dockerArgs.Add('1000:1000')
    $dockerArgs.Add('--cap-drop'); $dockerArgs.Add('ALL')
    $dockerArgs.Add('--security-opt'); $dockerArgs.Add('no-new-privileges')
    $dockerArgs.Add('--pids-limit'); $dockerArgs.Add('256')
    # network disabled by default; only Resolve-AirlockNetworkPolicy's
    # explicit "Enabled" verdict switches this to bridge.
    $dockerArgs.Add('--network'); $dockerArgs.Add($(if ($NetworkDecision -eq 'Enabled') { 'bridge' } else { 'none' }))
    $dockerArgs.Add('--cpus'); $dockerArgs.Add("$CpuLimit")
    $dockerArgs.Add('--memory'); $dockerArgs.Add($MemoryLimit)
    # only the job worktree is writable.
    $dockerArgs.Add('--mount'); $dockerArgs.Add("type=bind,source=$JobWorktreePath,target=/workspace,readonly=false")
    # read-only tool policy (allowedCommands, network, credentials mode).
    $dockerArgs.Add('--mount'); $dockerArgs.Add("type=bind,source=$PolicyFilePath,target=/policy/job-policy.json,readonly=true")
    $dockerArgs.Add('--read-only')
    $dockerArgs.Add('--tmpfs'); $dockerArgs.Add('/tmp')
    $dockerArgs.Add('--env'); $dockerArgs.Add("AIRLOCK_MAX_WALL_CLOCK_MINUTES=$MaxWallClockMinutes")
    $dockerArgs.Add('--env'); $dockerArgs.Add("AIRLOCK_MAX_TOOL_STEPS=$MaxToolSteps")
    $dockerArgs.Add('--env'); $dockerArgs.Add("AIRLOCK_POLICY_FILE=/policy/job-policy.json")
    $dockerArgs.Add('--workdir'); $dockerArgs.Add('/workspace')
    $dockerArgs.Add($ContainerImage)
    return $dockerArgs.ToArray()
}
