# Start-AgentSession.ps1 — ADR-012 §7.1
# The single entry point that turns a profile selection into either a
# published active-agent certificate or a fully-explained failure. Wires
# together every Phase A/B primitive: lock, profile selection, capability
# registry, the Ollama adapter, the workspace/OpenCode contract, and the
# certificate publisher. The happy path requires a real Ollama + OpenCode
# install to exercise (§10.2 live acceptance suite) - see
# Test-StartAgentSession.ps1 for what's unit-tested: -WhatIf's no-mutation
# guarantee and the profile-resolution failure path, both pure/mockable.
param(
    [string]$Profile,
    [Parameter(Mandatory)][ValidateSet('opencode', 'pi-worker', 'aider', 'openclaw')][string]$Harness,
    [int]$Context = 8192,
    [switch]$ForceVerify,
    [switch]$NoCache,
    [switch]$WhatIf,
    [string]$WorkspaceRoot,
    [string]$PlatformDir = "$env:USERPROFILE\.ai-platform",
    [string]$ProfileCataloguePath
)

# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by any of these dot-sourced files reassigning the same variable name.
. (Join-Path $PSScriptRoot "agent-state-helpers.ps1")
. (Join-Path $PSScriptRoot "agent-profile-helpers.ps1")
. (Join-Path $PSScriptRoot "agent-capability-registry.ps1")
. (Join-Path $PSScriptRoot "runtime-adapters" "ollama.ps1")
. (Join-Path $PSScriptRoot "Invoke-OpenCodeCapabilityContract.ps1")

if (-not $ProfileCataloguePath) { $ProfileCataloguePath = Join-Path $PSScriptRoot ".." "config" "agent-profiles.json" }
if (-not $WorkspaceRoot) { $WorkspaceRoot = Join-Path $PlatformDir "workspaces" }

$LockPath = Join-Path $PlatformDir "state" "bootstrap.lock"
$RegistryPath = Join-Path $PlatformDir "state" "capability-registry.json"
$CertificatePath = Join-Path $PlatformDir "state" "active-agent.json"
$OpenCodeConfigPath = "$env:USERPROFILE\.opencode\opencode.json"
$BackupDir = Join-Path $PlatformDir "state" "config-backups"
$TransactionDir = Join-Path $PlatformDir "state" "config-transactions"

# Reads the catalogue and resolves a profile - pure/read-only, safe to call
# both from -WhatIf's discovery-only path and from the real path (§7.1 step 2:
# "never auto-select a candidate merely because it is already installed").
function Resolve-SessionProfile {
    $catalogue = Get-AirlockProfileCatalogue -Path $ProfileCataloguePath
    foreach ($p in $catalogue) {
        $schema = Test-AirlockProfileSchema -Profile $p
        if (-not $schema.Valid) {
            Write-Host "ERROR: profile '$($p.profileId)' in the catalogue fails schema validation: $($schema.MissingFields -join ', ') $($schema.Error)" -ForegroundColor Red
            exit 1
        }
    }
    $selection = Resolve-AirlockProfileSelection -RequestedProfileId $Profile -AvailableProfiles $catalogue
    if (-not $selection.Selected) {
        Write-Host "FAILED: $($selection.Reason)" -ForegroundColor Red
        exit 1
    }
    return $selection.Selected
}

# --- §7.1: "-WhatIf performs discovery and prints the plan only. It never
# starts a process, pulls a model, writes state, invokes a harness, or
# changes a global configuration." Runs entirely before step 1 (lock
# acquisition) - even the lock file is state this must never write. ---
if ($WhatIf) {
    $selectedProfile = Resolve-SessionProfile
    $endpointMode = Resolve-OllamaEndpointMode -Harness $Harness
    Write-Host "WHATIF: would acquire lock at $LockPath" -ForegroundColor Cyan
    Write-Host "WHATIF: selected profile '$($selectedProfile.profileId)' ($($selectedProfile.displayName))" -ForegroundColor Cyan
    Write-Host "WHATIF: would try transports in order: $($endpointMode.TransportCandidates -join ', ')" -ForegroundColor Cyan
    Write-Host "WHATIF: would check capability registry at $RegistryPath (ForceVerify=$ForceVerify, NoCache=$NoCache)" -ForegroundColor Cyan
    Write-Host "WHATIF: would run the $Harness workspace contract in $WorkspaceRoot if no fresh capability entry exists" -ForegroundColor Cyan
    Write-Host "WHATIF: would publish $CertificatePath only on a passing contract" -ForegroundColor Cyan
    Write-Host "WHATIF: no process started, no model pulled, no state written, no harness invoked, no global config changed." -ForegroundColor Green
    exit 0
}

# --- Step 1: acquire the single user-scoped bootstrap lock ---
$lock = New-AirlockLock -LockPath $LockPath
try {
    # --- Step 2: resolve profile ---
    $selectedProfile = Resolve-SessionProfile

    # --- Step 4/5: start/adopt runtime, inspect (Ollama-only path in Phase B) ---
    if ($selectedProfile.runtime -ne 'ollama') {
        Write-Host "FAILED: runtime '$($selectedProfile.runtime)' has no adapter yet (Phase B implements Ollama only)." -ForegroundColor Red
        exit 1
    }
    $ollamaBaseUrl = Get-AirlockOllamaBaseUrl -PlatformDir $PlatformDir
    $discovery = Get-OllamaDiscovery -BaseUrl $ollamaBaseUrl
    if (-not $discovery.Reachable) {
        Write-Host "FAILED: Ollama is not reachable. Run ai-start first." -ForegroundColor Red
        exit 1
    }
    $inspection = Get-OllamaInspection -ModelRef $selectedProfile.modelRef -BaseUrl $ollamaBaseUrl
    if (-not $inspection.Found) {
        Write-Host "FAILED: model '$($selectedProfile.modelRef)' not found. Acquisition (§6 Acquire) is not implemented in this pass - pull it manually first." -ForegroundColor Red
        exit 1
    }

    $endpointMode = Resolve-OllamaEndpointMode -Harness $Harness
    $attempted = @{}
    $publishedCertificate = $null
    $failureReasons = @()

    while ($true) {
        $next = Resolve-AirlockNextTransport -TransportCandidatesInOrder $endpointMode.TransportCandidates -AttemptedResults $attempted
        if ($next.Done) {
            if ($next.Verdict -ne 'Pass') { $failureReasons += $next.Reason }
            break
        }

        # Same snapshot-file convention tool-proxy and hermes-container/run-hermes.ps1
        # use - the live port, not a fixed value (§7.1's endpoint identity must
        # match what Discover/Inspect actually probed, not a guessed default).
        $endpointBase = if ($next.Transport -eq 'ollama-openai-proxy') { Get-AirlockToolProxyBaseUrl -PlatformDir $PlatformDir } else { Get-AirlockOllamaBaseUrl -PlatformDir $PlatformDir }
        $endpointUrl = "$endpointBase/v1"
        $evidenceKey = Get-AirlockCapabilityEvidenceKey -ContractVersion "1" -ProfileId $selectedProfile.profileId `
            -ModelRef $selectedProfile.modelRef -ModelDigest $inspection.Digest -ArtifactHash $inspection.Digest `
            -Runtime "ollama" -RuntimeVersion $discovery.Version -EndpointMode $next.Transport -EndpointIdentity $endpointUrl `
            -RuntimeConfigHash "n/a" -ChatTemplateIdentity ($inspection.Template ?? "n/a") -EffectiveContext "$Context" `
            -KvCacheMode "default" -Harness $Harness -HarnessVersion "n/a" -HarnessConfigHash "n/a" `
            -ToolSurfaceHash $selectedProfile.toolSurface -SandboxPolicyVersion "1"

        # --- Step 6: read a fresh capability entry; run the contract only if absent/stale ---
        $cached = Get-AirlockCapabilityEntry -EvidenceKey $evidenceKey -RegistryPath $RegistryPath -ForceVerify:$ForceVerify -NoCache:$NoCache
        if ($cached.FromCache) {
            $contractPassed = ($cached.Entry.verdict -eq 'pass')
        } else {
            if ($Harness -ne 'opencode') {
                Write-Host "FAILED: only the OpenCode contract is implemented in this pass." -ForegroundColor Red
                exit 1
            }
            $contractResult = Invoke-AirlockOpenCodeCapabilityContract -ModelRef $selectedProfile.modelRef -EndpointUrl $endpointUrl `
                -OpenCodeConfigPath $OpenCodeConfigPath -LockPath (Join-Path $PlatformDir "state" "opencode-config.lock") `
                -BackupDir $BackupDir -TransactionDir $TransactionDir -WorkspaceRoot $WorkspaceRoot
            $contractPassed = $contractResult.Passed
            Set-AirlockCapabilityEntry -EvidenceKey $evidenceKey -RegistryPath $RegistryPath `
                -Verdict $(if ($contractPassed) { 'pass' } else { 'fail' }) `
                -EntryData ([pscustomobject]@{ profileId = $selectedProfile.profileId; modelDigest = $inspection.Digest; transport = $next.Transport; endpoint = $endpointUrl; harness = $Harness }) `
                -PassTtlMinutes 5 -FailTtlMinutes 1 -NoCache:$NoCache | Out-Null
        }

        $attempted[$next.Transport] = if ($contractPassed) { 'Pass' } else { 'Fail' }
        if (-not $contractPassed) { $failureReasons += "Transport '$($next.Transport)' failed the capability contract." }
        else {
            $publishedCertificate = [pscustomobject]@{
                schemaVersion         = 1
                sessionId             = $lock.sessionId
                profileId             = $selectedProfile.profileId
                model                 = $selectedProfile.modelRef
                modelDigest           = $inspection.Digest
                runtime               = [pscustomobject]@{ name = "ollama"; version = $discovery.Version }
                transport             = [pscustomobject]@{ mode = $next.Transport; endpoint = $endpointUrl }
                effectiveContext      = $Context
                harness               = $Harness
                capabilityEvidenceKey = $evidenceKey
                sandboxPolicyVersion  = 1
                provenAt              = [DateTime]::UtcNow.ToString('o')
                expiresAt             = [DateTime]::UtcNow.AddMinutes(5).ToString('o')
            }
        }
    }

    # --- Step 8/9: publish only on pass; a failure never mutates a prior certificate (I-03) ---
    $publishResult = Publish-AirlockActiveAgentCertificate -CertificatePath $CertificatePath `
        -Certificate ($publishedCertificate ?? [pscustomobject]@{}) -ContractPassed ([bool]$publishedCertificate)

    if ($publishedCertificate) {
        Write-Host "SUCCESS: $($publishResult.Reason)" -ForegroundColor Green
        exit 0
    }
    Write-Host "FAILED: no transport passed. Reasons:" -ForegroundColor Red
    $failureReasons | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    exit 1
} finally {
    # --- Step 10: release the lock after all session-owned resources are handled ---
    Remove-AirlockLock -LockPath $LockPath -SessionId $lock.sessionId
}
