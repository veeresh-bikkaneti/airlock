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
    [switch]$DownloadConfirmed,
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
. (Join-Path $PSScriptRoot "runtime-adapters" "llamacpp.ps1")
. (Join-Path $PSScriptRoot "runtime-adapters" "lmstudio.ps1")
. (Join-Path $PSScriptRoot "Get-HuggingFaceGguf.ps1")
. (Join-Path $PSScriptRoot "Invoke-OpenCodeCapabilityContract.ps1")
. (Join-Path $PSScriptRoot "Invoke-PiCapabilityContract.ps1")

# Runtime-agnostic endpoint-mode dispatch, used by both -WhatIf (to print the
# plan the real path will actually follow) and the real path. Found by
# review: -WhatIf used to hardcode Resolve-OllamaEndpointMode regardless of
# the selected profile's runtime, so a non-Ollama profile's -WhatIf printed
# a transport plan the real path would never attempt.
function Resolve-SessionEndpointMode {
    param([Parameter(Mandatory)][string]$Runtime, [Parameter(Mandatory)][string]$Harness)
    switch ($Runtime) {
        'ollama' { return Resolve-OllamaEndpointMode -Harness $Harness }
        'llama-server' { return Resolve-LlamaCppEndpointMode -Harness $Harness }
        'lmstudio' { return Resolve-LMStudioEndpointMode -Harness $Harness }
        default { return [pscustomobject]@{ TransportCandidates = @(); Reason = "No adapter for runtime '$Runtime' yet." } }
    }
}

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
    $endpointMode = Resolve-SessionEndpointMode -Runtime $selectedProfile.runtime -Harness $Harness
    Write-Host "WHATIF: would acquire lock at $LockPath" -ForegroundColor Cyan
    Write-Host "WHATIF: selected profile '$($selectedProfile.profileId)' ($($selectedProfile.displayName))" -ForegroundColor Cyan
    Write-Host "WHATIF: would try transports in order: $($endpointMode.TransportCandidates -join ', ')" -ForegroundColor Cyan
    Write-Host "WHATIF: would check capability registry at $RegistryPath (ForceVerify=$ForceVerify, NoCache=$NoCache)" -ForegroundColor Cyan
    Write-Host "WHATIF: would run the $Harness workspace contract in $WorkspaceRoot if no fresh capability entry exists" -ForegroundColor Cyan
    Write-Host "WHATIF: would publish $CertificatePath only on a passing contract" -ForegroundColor Cyan
    if ($selectedProfile.runtime -eq 'llama-server') {
        Write-Host "WHATIF: would enforce VRAM gate vs $($selectedProfile.minimumFreeVramGiB) GiB and start llama-server with HealthTimeoutSec=300 if no healthy snapshot for this GGUF" -ForegroundColor Cyan
        $ggufDest = Get-AirlockGgufDestPath -ModelRef $selectedProfile.modelRef -PlatformDir $PlatformDir
        if ((Test-Path $ggufDest) -and -not (Test-AirlockGgufEvidenceMatch -ByteLength ([long](Get-Item $ggufDest).Length))) {
            Write-Host "WHATIF: GGUF at $ggufDest is not $script:AirlockGgufEvidenceBytes bytes - would ForceVerify (do not inherit the 3/3)" -ForegroundColor Yellow
        }
    }
    Write-Host "WHATIF: no process started, no model pulled, no state written, no harness invoked, no global config changed." -ForegroundColor Green
    exit 0
}

# --- Step 1: acquire the single user-scoped bootstrap lock ---
$lock = New-AirlockLock -LockPath $LockPath
try {
    # BUG FOUND BY A LIVE RUN: a hung workspace trial (fixed with a
    # per-process timeout in Invoke-OpenCodeCapabilityContract.ps1) or this
    # orchestrator being killed from outside can abandon a harness config
    # transaction mid-flight, leaving the real global config (e.g.
    # ~/.opencode/opencode.json) replaced with Airlock's staged content
    # indefinitely. Get-AirlockOrphanedHarnessTransactions and
    # Resolve-AirlockConfigRestore already existed for exactly this but
    # nothing called them - swept here, on every real run, before anything
    # else touches a harness config.
    Invoke-AirlockOrphanedHarnessTransactionRecovery -TransactionDir $TransactionDir | ForEach-Object {
        Write-Host "RECOVERED: orphaned config transaction for session $($_.SessionId) ($($_.Action) on $($_.ConfigPath))" -ForegroundColor Yellow
    }

    # --- Step 2: resolve profile ---
    $selectedProfile = Resolve-SessionProfile

    # --- Step 4/5: start/adopt runtime, inspect. One branch per adapter -
    # the shapes genuinely differ: Ollama assumes an always-on daemon that
    # already has models resident (Discover then Inspect); llama-server
    # starts exactly one model per process and has no persistent daemon to
    # discover (an instance must already be running - Acquire/Start
    # automation isn't implemented in this pass, matching Ollama's own
    # missing-model gap below); LM Studio is a local server you start
    # yourself, discoverable via its own API once running. Every branch
    # ends with $runtimeVersion/$modelDigest/$chatTemplateIdentity set so
    # the evidence key and certificate below aren't Ollama-specific either. ---
    $runtimeVersion = $null
    $modelDigest = $null
    $chatTemplateIdentity = "n/a"
    $gguf = $null
    $ollamaLivePassThisRun = $false

    switch ($selectedProfile.runtime) {
        'ollama' {
            $baseUrl = Get-AirlockOllamaBaseUrl -PlatformDir $PlatformDir
            $discovery = Get-OllamaDiscovery -BaseUrl $baseUrl
            if (-not $discovery.Reachable) {
                Write-Host "FAILED: Ollama is not reachable. Run ai-start first." -ForegroundColor Red
                exit 1
            }
            $inspection = Get-OllamaInspection -ModelRef $selectedProfile.modelRef -BaseUrl $baseUrl
            if (-not $inspection.Found) {
                Write-Host "FAILED: model '$($selectedProfile.modelRef)' not found. Acquisition (§6 Acquire) is not implemented in this pass - pull it manually first." -ForegroundColor Red
                exit 1
            }
            $runtimeVersion = $discovery.Version
            $modelDigest = $inspection.Digest
            $chatTemplateIdentity = $inspection.Template ?? "n/a"
        }
        'llama-server' {
            $runtimeArgs = @($selectedProfile.runtimeArgs)
            $requiresGpuAll = (($runtimeArgs -join ' ') -match 'n-gpu-layers') -and ($runtimeArgs -contains 'all')
            $freeVramGiB = Get-AirlockFreeVramGiB
            $vramGate = Resolve-AirlockVramStartGate -FreeVramGiB $freeVramGiB -MinimumFreeVramGiB ([double]$selectedProfile.minimumFreeVramGiB) -RequiresGpuLayersAll $requiresGpuAll
            if (-not $vramGate.Allowed) {
                Write-Host "FAILED: $($vramGate.Reason)" -ForegroundColor Red
                exit 1
            }

            $gguf = Get-AirlockHuggingFaceGguf -ModelRef $selectedProfile.modelRef -PlatformDir $PlatformDir -UserConfirmed:$DownloadConfirmed
            if (-not $gguf.Ready) {
                Write-Host "FAILED: $($gguf.Reason)" -ForegroundColor Red
                exit 1
            }
            if ($gguf.ForceVerify) { $ForceVerify = $true }

            $baseUrl = Get-AirlockLlamaCppBaseUrl -PlatformDir $PlatformDir
            $needStart = $true
            if ($baseUrl) {
                $snapFile = Join-Path $PlatformDir "state" "llamacpp-instance.json"
                $snapPath = $null
                if (Test-Path $snapFile) {
                    try { $snapPath = (Get-Content $snapFile -Raw | ConvertFrom-Json).modelPath } catch { $snapPath = $null }
                }
                if ($snapPath -eq $gguf.Path -and (Test-LlamaCppPort -BaseUrl $baseUrl)) {
                    $needStart = $false
                }
            }
            if ($needStart) {
                Stop-LlamaCppIfOwned -PlatformDir $PlatformDir | Out-Null
                $started = Start-LlamaCppRuntime -ModelPath $gguf.Path -Context ([int]$selectedProfile.initialContext) `
                    -RuntimeArgs $runtimeArgs -PlatformDir $PlatformDir
                if (-not $started.Started) {
                    Write-Host "FAILED: $($started.Reason)" -ForegroundColor Red
                    exit 1
                }
                $baseUrl = $started.BaseUrl
            }
            $inspection = Get-LlamaCppInspection -BaseUrl $baseUrl
            if (-not $inspection.Reachable -or $inspection.TemplateVerdict -ne 'Pass') {
                Write-Host "FAILED: llama-server template verification failed: $($inspection.Reason)" -ForegroundColor Red
                exit 1
            }
            $runtimeVersion = "unknown"
            $modelDigest = $inspection.TemplateIdentity
            $chatTemplateIdentity = $inspection.TemplateIdentity
        }
        'lmstudio' {
            $baseUrl = Get-LMStudioBaseUrl -PlatformDir $PlatformDir
            $inspection = Get-LMStudioInspection -ModelRef $selectedProfile.modelRef -BaseUrl $baseUrl
            if (-not $inspection.Found -or $inspection.Verdict -ne 'Pass') {
                Write-Host "FAILED: LM Studio model verification failed: $($inspection.Reason)" -ForegroundColor Red
                exit 1
            }
            # LM Studio documents no server/build-version endpoint anywhere
            # (see lmstudio.ps1's header) - Get-AirlockCapabilityEvidenceKey's
            # RuntimeVersion is mandatory, so this sentinel makes the gap
            # visible rather than inventing a real-looking value.
            $runtimeVersion = "unknown"
            $modelDigest = $inspection.ModelId
            $chatTemplateIdentity = $inspection.ToolKind
        }
        default {
            Write-Host "FAILED: runtime '$($selectedProfile.runtime)' has no adapter yet." -ForegroundColor Red
            exit 1
        }
    }

    $endpointMode = Resolve-SessionEndpointMode -Runtime $selectedProfile.runtime -Harness $Harness
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
        # Only Ollama has a direct/proxy port split to resolve here - llama-server
        # and LM Studio have exactly one transport candidate, so $baseUrl (already
        # resolved and validated in the runtime switch above) is the endpoint.
        $endpointBase = if ($selectedProfile.runtime -eq 'ollama') {
            if ($next.Transport -eq 'ollama-openai-proxy') { Get-AirlockToolProxyBaseUrl -PlatformDir $PlatformDir } else { Get-AirlockOllamaBaseUrl -PlatformDir $PlatformDir }
        } else {
            $baseUrl
        }
        $endpointUrl = "$endpointBase/v1"
        $evidenceKey = Get-AirlockCapabilityEvidenceKey -ContractVersion "1" -ProfileId $selectedProfile.profileId `
            -ModelRef $selectedProfile.modelRef -ModelDigest $modelDigest -ArtifactHash $(if ($gguf -and $gguf.Sha256) { $gguf.Sha256 } else { $modelDigest }) `
            -Runtime $selectedProfile.runtime -RuntimeVersion $runtimeVersion -EndpointMode $next.Transport -EndpointIdentity $endpointUrl `
            -RuntimeConfigHash "n/a" -ChatTemplateIdentity $chatTemplateIdentity -EffectiveContext "$Context" `
            -KvCacheMode "default" -Harness $Harness -HarnessVersion "n/a" -HarnessConfigHash "n/a" `
            -ToolSurfaceHash $selectedProfile.toolSurface -SandboxPolicyVersion "1"

        # --- Step 6: read a fresh capability entry; run the contract only if absent/stale ---
        $cached = Get-AirlockCapabilityEntry -EvidenceKey $evidenceKey -RegistryPath $RegistryPath -ForceVerify:$ForceVerify -NoCache:$NoCache
        $fitState = $null
        $contractResult = $null
        $transportReturnedValidToolEvents = $false
        if ($cached.FromCache) {
            $contractPassed = ($cached.Entry.verdict -eq 'pass')
            # Restore persisted transport validity from cache entry
            $transportReturnedValidToolEvents = $cached.Entry.transportReturnedValidToolEvents ?? $false
        } else {
            # §7.3: each harness implements its own invocation wrapper around
            # the shared §7.2 workspace contract - dispatch to the one that
            # matches, never silently reuse another harness's contract.
            $contractResult = switch ($Harness) {
                'opencode' {
                    Invoke-AirlockOpenCodeCapabilityContract -ModelRef $selectedProfile.modelRef -EndpointUrl $endpointUrl `
                        -OpenCodeConfigPath $OpenCodeConfigPath -LockPath (Join-Path $PlatformDir "state" "opencode-config.lock") `
                        -BackupDir $BackupDir -TransactionDir $TransactionDir -WorkspaceRoot $WorkspaceRoot
                }
                'pi-worker' {
                    Invoke-AirlockPiCapabilityContract -ModelRef $selectedProfile.modelRef -EndpointUrl $endpointUrl -WorkspaceRoot $WorkspaceRoot
                }
                default {
                    Write-Host "FAILED: no contract for harness '$Harness' is implemented in this pass." -ForegroundColor Red
                    exit 1
                }
            }
            $contractPassed = $contractResult.Passed
            $transportReturnedValidToolEvents = $contractResult.TransportReturnedValidToolEvents
            if ($contractPassed -and $selectedProfile.runtime -eq 'ollama') { $ollamaLivePassThisRun = $true }
            Set-AirlockCapabilityEntry -EvidenceKey $evidenceKey -RegistryPath $RegistryPath `
                -Verdict $(if ($contractPassed) { 'pass' } else { 'fail' }) `
                -EntryData ([pscustomobject]@{ profileId = $selectedProfile.profileId; modelDigest = $modelDigest; transport = $next.Transport; endpoint = $endpointUrl; harness = $Harness; transportReturnedValidToolEvents = $transportReturnedValidToolEvents }) `
                -PassTtlMinutes 5 -FailTtlMinutes 1 -NoCache:$NoCache | Out-Null
        }

        # §4.1's three independent fit states, wired here (not just built
        # and unit-tested) so a failure names WHICH dimension didn't fit
        # instead of a single folded "contract failed". Enforced as sole
        # publish gate for Ollama (the only runtime with measurements); other
        # runtimes use contract pass as their gate (honest gap, not blocker).
        if ($selectedProfile.runtime -eq 'ollama') {
            $freeVramGiB = Get-AirlockFreeVramGiB
            if ($null -ne $freeVramGiB) {
                $fitState = Resolve-AirlockFitState -FreeVramGiB $freeVramGiB -MinimumFreeVramGiB $selectedProfile.minimumFreeVramGiB `
                    -Residency $inspection.Residency -TransportReturnedValidToolEvents $transportReturnedValidToolEvents `
                    -HarnessContractPassed $contractPassed
                if (-not $fitState.CodingReady) {
                    $dims = @()
                    if (-not $fitState.ArtifactFit) { $dims += "artifact (${freeVramGiB}GiB free vs $($selectedProfile.minimumFreeVramGiB)GiB required, residency=$($inspection.Residency))" }
                    if (-not $fitState.TransportFit) { $dims += "transport (no valid structured tool events)" }
                    if (-not $fitState.HarnessFit) { $dims += "harness (capability contract failed)" }
                    $failureReasons += "Transport '$($next.Transport)' is not coding-ready: $($dims -join '; ')."
                    $contractPassed = $false
                }
            } else {
                $failureReasons += "Transport '$($next.Transport)': cannot measure free VRAM (nvidia-smi unavailable or failed)."
                $contractPassed = $false
            }
        }

        $attempted[$next.Transport] = if ($contractPassed) { 'Pass' } else { 'Fail' }
        if (-not $contractPassed) { $failureReasons += "Transport '$($next.Transport)' failed the capability contract." }
        else {
            $publishedCertificate = [pscustomobject]@{
                schemaVersion         = 1
                sessionId             = $lock.sessionId
                profileId             = $selectedProfile.profileId
                model                 = $selectedProfile.modelRef
                modelDigest           = $modelDigest
                runtime               = [pscustomobject]@{ name = $selectedProfile.runtime; version = $runtimeVersion }
                transport             = [pscustomobject]@{ mode = $next.Transport; endpoint = $endpointUrl }
                effectiveContext      = $Context
                harness               = $Harness
                capabilityEvidenceKey = $evidenceKey
                sandboxPolicyVersion  = 1
                provenAt              = [DateTime]::UtcNow.ToString('o')
                expiresAt             = [DateTime]::UtcNow.AddMinutes(5).ToString('o')
                fitState              = $fitState
                provenance            = if ($gguf) {
                    [pscustomobject]@{
                        ggufBytes            = $gguf.Bytes
                        ggufSha256           = $gguf.Sha256
                        matchedEvidenceBytes = $gguf.MatchedEvidenceBytes
                    }
                } else { $null }
            }
        }
    }

    if ($selectedProfile.runtime -eq 'ollama') {
        $ollamaGate = Resolve-AirlockOllamaCodingCertificate -LiveContractPassedThisRun $ollamaLivePassThisRun
        if (-not $ollamaGate.Allow) {
            $publishedCertificate = $null
            $failureReasons += $ollamaGate.Reason
            Write-Host "REFUSED: $($ollamaGate.Reason)" -ForegroundColor Yellow
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
