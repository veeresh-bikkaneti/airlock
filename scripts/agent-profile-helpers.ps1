# agent-profile-helpers.ps1 — ADR-012 (docs/adr/2026-08-20-local-first-agent-fabric-design.md)
# Phase B: profile schema validation, explicit-selection rule, fit-state
# decisions (§4.1), and transport-candidate ordering (§7.1/§12.2). Pure
# decision functions only — no runtime/network/GPU I/O — so they're testable
# without a real Ollama, model, or GPU. See Test-AgentProfileHelpers.ps1.

$RequiredProfileFields = @(
    'profileId', 'displayName', 'runtime', 'transportCandidates', 'modelRef',
    'acquisition', 'initialContext', 'minimumFreeVramGiB', 'toolSurface', 'candidateOnly'
)

function Get-AirlockProfileCatalogue {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Profile catalogue not found at $Path"
    }
    $catalogue = Get-Content $Path -Raw | ConvertFrom-Json
    return $catalogue.profiles
}

# §5.1: "This is source-controlled policy." Validates shape only.
# ADR-012 originally forbade candidateOnly=false so a human could not
# declare a passing verdict by flipping a JSON flag. ADR-013 D2 then
# earned false for llamacpp-qwen38-ud-q3-k-xl via a live 3/3 Pi contract.
# Rejecting false made that proven profile fail schema, so every
# Start-AgentSession (which validates the whole catalogue) exited 1 and
# CI Test-AgentProfileHelpers.ps1 failed. Both JSON booleans are valid:
# true = unproven candidate, false = a live contract earned promotion.
# The flag is still not a certificate — Start-AgentSession publishes
# active-agent.json only after a harness pass (AIR-016).
function Test-AirlockProfileSchema {
    param([Parameter(Mandatory)]$Profile)
    $missing = @($RequiredProfileFields | Where-Object { -not ($Profile.PSObject.Properties.Name -contains $_) })
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{ Valid = $false; MissingFields = $missing }
    }
    if ($Profile.candidateOnly -isnot [bool]) {
        return [pscustomobject]@{ Valid = $false; MissingFields = @(); Error = "candidateOnly must be a JSON boolean (true=unproven, false=earned by a live contract)." }
    }
    return [pscustomobject]@{ Valid = $true; MissingFields = @() }
}

# §7.1 step 2: "Resolve selected profile; never auto-select a candidate
# merely because it is already installed." An explicit -Profile request is
# required; an installed model with no request is not a selection.
function Resolve-AirlockProfileSelection {
    param(
        [string]$RequestedProfileId,
        [Parameter(Mandatory)][object[]]$AvailableProfiles,
        [string[]]$InstalledProfileIds = @()
    )
    if (-not $RequestedProfileId) {
        return [pscustomobject]@{ Selected = $null; Reason = "No profile explicitly requested - installed-but-unrequested candidates are never auto-selected." }
    }
    $match = $AvailableProfiles | Where-Object { $_.profileId -eq $RequestedProfileId } | Select-Object -First 1
    if (-not $match) {
        return [pscustomobject]@{ Selected = $null; Reason = "Requested profile '$RequestedProfileId' is not in the catalogue." }
    }
    return [pscustomobject]@{ Selected = $match; Reason = "Explicitly requested and found in the catalogue." }
}

# Host-level free VRAM in GiB via nvidia-smi, for Resolve-AirlockFitState's
# ArtifactFit input. Returns $null (not 0) when nvidia-smi is absent or
# unparsable, so a caller can tell "no GPU info available" apart from
# "confirmed zero free VRAM" rather than treating both the same way.
function Get-AirlockFreeVramGiB {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $null }
    try {
        $raw = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $freeMiB = [double](($raw | Select-Object -First 1) -replace '\s', '')
        return $freeMiB / 1024
    } catch {
        return $null
    }
}

# §4.1: three independent eligibility states, all required for coding-ready.
# Pure given already-measured inputs - the caller (Start-AgentSession.ps1)
# is responsible for actually measuring VRAM/residency/contract results.
function Resolve-AirlockFitState {
    param(
        [Parameter(Mandatory)][double]$FreeVramGiB,
        [Parameter(Mandatory)][double]$MinimumFreeVramGiB,
        [Parameter(Mandatory)][ValidateSet('Full', 'PartialOffload', 'CpuOnly')][string]$Residency,
        [Parameter(Mandatory)][bool]$TransportReturnedValidToolEvents,
        [Parameter(Mandatory)][bool]$HarnessContractPassed
    )
    # artifact-fit: policy floor met AND no unacceptable CPU offload. A
    # model that spills off-GPU "fits" the VRAM number on paper but the ADR
    # explicitly forbids treating that as fit (§4.1, §12.6).
    $artifactFit = ($FreeVramGiB -ge $MinimumFreeVramGiB) -and ($Residency -ne 'CpuOnly')
    $transportFit = $TransportReturnedValidToolEvents
    $harnessFit = $HarnessContractPassed
    return [pscustomobject]@{
        ArtifactFit  = $artifactFit
        TransportFit = $transportFit
        HarnessFit   = $harnessFit
        CodingReady  = ($artifactFit -and $transportFit -and $harnessFit)
    }
}

# §7.1 step 7 + §12.2: try transport candidates in profile order; a proxy
# fallback is attempted only after direct failure; never route a direct
# profile that already passed to the proxy.
function Resolve-AirlockNextTransport {
    param(
        [Parameter(Mandatory)][string[]]$TransportCandidatesInOrder,
        [Parameter(Mandatory)][hashtable]$AttemptedResults  # transport -> 'Pass' | 'Fail' (absent = not yet tried)
    )
    foreach ($transport in $TransportCandidatesInOrder) {
        $result = $AttemptedResults[$transport]
        if ($result -eq 'Pass') {
            return [pscustomobject]@{ Transport = $null; Done = $true; Verdict = 'Pass'; PassedTransport = $transport; Reason = "'$transport' already passed - stop, never continue probing further candidates (including any proxy fallback) once a direct pass is recorded." }
        }
        if (-not $result) {
            $isProxy = $transport -match 'proxy'
            if ($isProxy) {
                $priorDirect = $TransportCandidatesInOrder | Where-Object { $_ -ne $transport -and -not ($_ -match 'proxy') }
                $anyDirectFailed = $priorDirect | Where-Object { $AttemptedResults[$_] -eq 'Fail' }
                $anyDirectUntried = $priorDirect | Where-Object { -not $AttemptedResults[$_] }
                if ($anyDirectUntried) {
                    continue  # a direct candidate ahead of this proxy hasn't been tried yet - respect profile order.
                }
                if (-not $anyDirectFailed) {
                    return [pscustomobject]@{ Transport = $null; Done = $true; Verdict = 'Fail'; PassedTransport = $null; Reason = "No direct transport failed, so the proxy fallback is not attempted (proxy only follows direct failure)." }
                }
            }
            return [pscustomobject]@{ Transport = $transport; Done = $false; Verdict = $null; PassedTransport = $null; Reason = "Next untried candidate in profile order." }
        }
    }
    return [pscustomobject]@{ Transport = $null; Done = $true; Verdict = 'Fail'; PassedTransport = $null; Reason = "Every candidate in profile order was tried and none passed." }
}

# A healthy already-running llama-server instance serving the exact
# requested GGUF needs no new process, so it must never be blocked by the
# VRAM start-gate below (that gate only makes sense when something new is
# about to start). Pure/mockable: takes already-resolved values instead of
# touching the snapshot file or the port itself.
function Resolve-AirlockLlamaCppNeedsStart {
    param(
        [AllowNull()][string]$SnapshotModelPath,
        [Parameter(Mandatory)][string]$RequestedModelPath,
        [Parameter(Mandatory)][bool]$PortReachable
    )
    return -not ($SnapshotModelPath -eq $RequestedModelPath -and $PortReachable)
}

# AIR-016 D9: cheap VRAM gate before llama-server start. Full residency
# measurement stays FIT-ADAPTERS-001. $FreeVramGiB is $null when nvidia-smi
# is missing (Get-AirlockFreeVramGiB); that is not the same as 0. Only ever
# call this when Resolve-AirlockLlamaCppNeedsStart says a new process is
# actually about to start - reusing an already-running instance needs zero
# new VRAM, so gating on it exits genuinely healthy sessions (e.g. a cert
# renewal after -PassTtlMinutes 5 expiry with the same model already loaded).
function Resolve-AirlockVramStartGate {
    param(
        [AllowNull()]$FreeVramGiB,
        [Parameter(Mandatory)][double]$MinimumFreeVramGiB,
        [bool]$RequiresGpuLayersAll = $false
    )
    if ($null -eq $FreeVramGiB) {
        if ($RequiresGpuLayersAll) {
            return [pscustomobject]@{ Allowed = $false; Reason = "nvidia-smi is missing or unparsable; this profile requires GPU layers all. Refusing to start." }
        }
        return [pscustomobject]@{ Allowed = $false; Reason = "cannot measure free VRAM (nvidia-smi unavailable). Refusing to start." }
    }
    $free = [double]$FreeVramGiB
    if ($free -lt $MinimumFreeVramGiB) {
        return [pscustomobject]@{ Allowed = $false; Reason = "free VRAM $([math]::Round($free, 2)) GiB is below the profile floor of $MinimumFreeVramGiB GiB." }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = "VRAM gate passed ($([math]::Round($free, 2)) GiB free >= $MinimumFreeVramGiB GiB)." }
}

# AIR-016 D7: Ollama coding certificates require a live pass in THIS run.
# A cached capability hit or candidateOnly flag is not enough.
function Resolve-AirlockOllamaCodingCertificate {
    param([Parameter(Mandatory)][bool]$LiveContractPassedThisRun)
    if ($LiveContractPassedThisRun) {
        return [pscustomobject]@{ Allow = $true; Reason = "A live capability contract passed in this run." }
    }
    return [pscustomobject]@{
        Allow  = $false
        Reason = "Ollama has no passing agentic verdict on this hardware (qwen2.5-coder:7b, qwen3-coder:30b 0/6, devstral-small-2:24b). Use ai-start for chat, ai-agent-start for coding. A cached pass is not a certificate."
    }
}
