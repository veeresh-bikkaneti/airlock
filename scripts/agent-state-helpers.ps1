# agent-state-helpers.ps1 — ADR-012 (docs/adr/2026-08-20-local-first-agent-fabric-design.md)
# Phase A: shared lock / atomic-write / capability-evidence-key / certificate
# primitives used by Invoke-HarnessConfigTransaction.ps1 and (from Phase B on)
# Start-AgentSession.ps1. Dot-source this file rather than calling it directly.
#
# Pure decision functions are kept separate from their I/O wrappers, same
# convention as Get-BackendCapability.ps1 (Test-VLLMViable) and
# profile-helpers.ps1 (Resolve-ClaudeOnStash/Off) — makes them testable
# without real processes or a real filesystem. See Test-AgentStateHelpers.ps1.

# Atomic write: same-directory temp file + File.Move(overwrite) is a single
# filesystem rename on the same volume, so a reader never observes a
# partially-written file. ADR §5.3/I-03 requires this for active-agent.json
# (only success atomically replaces a prior certificate) and §8.1 requires it
# for staged harness config.
function Write-AirlockAtomicJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data,
        [int]$Depth = 10
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $tempPath = Join-Path $dir ".$([System.IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp"
    ($Data | ConvertTo-Json -Depth $Depth) | Set-Content -Path $tempPath -Encoding utf8NoBOM -NoNewline
    [System.IO.File]::Move($tempPath, $Path, $true)
}

# Pure: given what's on disk (if anything) and whether its recorded owner is
# still alive, decide whether taking the lock is allowed. §7.1 "Acquire the
# single user-scoped bootstrap lock"; §8.1 "stale takeover requires a dead
# verified owner or explicit recovery".
function Resolve-LockTakeover {
    param(
        [Parameter(Mandatory)][bool]$LockExists,
        [bool]$OwnerAlive = $false,
        [switch]$ForceRecover
    )
    if (-not $LockExists) {
        return [pscustomobject]@{ Allowed = $true; Reason = "No existing lock." }
    }
    if ($OwnerAlive -and -not $ForceRecover) {
        return [pscustomobject]@{ Allowed = $false; Reason = "Lock held by a live, verified owner." }
    }
    if ($OwnerAlive -and $ForceRecover) {
        return [pscustomobject]@{ Allowed = $false; Reason = "Refusing -ForceRecover against a live, verified owner." }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = "Existing lock's owner is dead or stale - safe takeover." }
}

function New-AirlockLock {
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [switch]$ForceRecover
    )
    $lockExists = Test-Path $LockPath
    $ownerAlive = $false
    if ($lockExists) {
        $existing = Get-Content $LockPath -Raw | ConvertFrom-Json
        $ownerProc = Get-Process -Id $existing.ownerPid -ErrorAction SilentlyContinue
        # Compare as UTC ticks (Int64), not an ISO-8601 string: ConvertFrom-Json
        # auto-detects date-shaped strings and reparses them as [DateTime],
        # silently truncating sub-second precision - a same-second false
        # "owner alive" mismatch would misclassify a live owner as stale.
        $ownerAlive = [bool]($ownerProc -and ($ownerProc.StartTime.ToUniversalTime().Ticks -eq $existing.ownerStartTimeTicks))
    }
    $decision = Resolve-LockTakeover -LockExists $lockExists -OwnerAlive $ownerAlive -ForceRecover:$ForceRecover
    if (-not $decision.Allowed) {
        throw "Cannot acquire lock at $LockPath : $($decision.Reason)"
    }

    $proc = Get-Process -Id $PID
    $lockData = [ordered]@{
        sessionId            = [guid]::NewGuid().ToString()
        ownerPid             = $PID
        ownerStartTimeTicks  = $proc.StartTime.ToUniversalTime().Ticks
        acquiredAt           = [DateTime]::UtcNow.ToString('o')
    }
    Write-AirlockAtomicJson -Path $LockPath -Data $lockData
    return [pscustomobject]$lockData
}

function Remove-AirlockLock {
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][string]$SessionId
    )
    if (-not (Test-Path $LockPath)) { return }
    $existing = Get-Content $LockPath -Raw | ConvertFrom-Json
    if ($existing.sessionId -ne $SessionId) {
        throw "Refusing to release lock at $LockPath : held by a different session ($($existing.sessionId)), not $SessionId."
    }
    Remove-Item $LockPath -Force
}

# ADR §5.2 evidence key. Component order and set are fixed by the spec's own
# code block — do not reorder or drop one; every component must move the
# hash (see Test-AgentStateHelpers.ps1's per-component mutation test).
# proxyVersion is the one component allowed to be empty (null only in direct
# transport modes per §5.2) — every other component is mandatory.
function Get-AirlockCapabilityEvidenceKey {
    param(
        [Parameter(Mandatory)][string]$ContractVersion,
        [Parameter(Mandatory)][string]$ProfileId,
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$ModelDigest,
        [Parameter(Mandatory)][string]$ArtifactHash,
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][string]$RuntimeVersion,
        [Parameter(Mandatory)][string]$EndpointMode,
        [Parameter(Mandatory)][string]$EndpointIdentity,
        [Parameter(Mandatory)][string]$RuntimeConfigHash,
        [Parameter(Mandatory)][string]$ChatTemplateIdentity,
        [Parameter(Mandatory)][string]$EffectiveContext,
        [Parameter(Mandatory)][string]$KvCacheMode,
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][string]$HarnessVersion,
        [Parameter(Mandatory)][string]$HarnessConfigHash,
        [Parameter(Mandatory)][string]$ToolSurfaceHash,
        [Parameter(Mandatory)][string]$SandboxPolicyVersion,
        [AllowEmptyString()][string]$ProxyVersion = ''
    )
    $components = @(
        $ContractVersion, $ProfileId, $ModelRef, $ModelDigest, $ArtifactHash, $Runtime, $RuntimeVersion,
        $EndpointMode, $EndpointIdentity, $RuntimeConfigHash, $ChatTemplateIdentity, $EffectiveContext,
        $KvCacheMode, $Harness, $HarnessVersion, $HarnessConfigHash, $ToolSurfaceHash, $SandboxPolicyVersion,
        $ProxyVersion
    )
    # Unit separator (0x1F) join: components are free text (paths, hashes,
    # identifiers) that could themselves contain a plain delimiter like "|",
    # which would let two different component sets hash identically.
    $joined = $components -join [char]0x1F
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return "sha256:$hex"
}

# ADR §5.3/I-03: a failed bootstrap never mutates a prior active-agent.json;
# only success atomically replaces it. The gate lives here, before the
# atomic writer is ever called, so a failed contract cannot reach the writer
# at all.
function Publish-AirlockActiveAgentCertificate {
    param(
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)]$Certificate,
        [Parameter(Mandatory)][bool]$ContractPassed
    )
    if (-not $ContractPassed) {
        return [pscustomobject]@{ Published = $false; Reason = "Contract did not pass - prior certificate (if any) left untouched." }
    }
    Write-AirlockAtomicJson -Path $CertificatePath -Data $Certificate
    return [pscustomobject]@{ Published = $true; Reason = "Contract passed - certificate atomically replaced." }
}
