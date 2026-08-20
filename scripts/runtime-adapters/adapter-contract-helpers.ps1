# scripts/runtime-adapters/adapter-contract-helpers.ps1 — ADR-012 §5.1/§6
# Runtime-agnostic halves of the §6 adapter contract: the acquisition gate
# (confirmation + no-parallel-pulls, §5.1) and StopIfOwned's ownership check
# (PID + start time + instance nonce, §6). Neither is Ollama-specific -
# llama.cpp (§6.2) and LM Studio (§6.3) adapters reuse these directly rather
# than each growing their own copy. Only Discover/Acquire/Start/Inspect I/O
# and endpoint-mode routing are genuinely runtime-local; those stay in each
# runtime's own file (see ollama.ps1).

# §5.1/§5.2: "The profile installer asks for confirmation before any
# multi-gigabyte download. It never starts parallel model pulls."
function Resolve-AirlockAcquisitionGate {
    param(
        [Parameter(Mandatory)][bool]$RequiresConfirmation,
        [bool]$UserConfirmed = $false,
        [bool]$AnotherPullAlreadyInProgress = $false
    )
    if ($AnotherPullAlreadyInProgress) {
        return [pscustomobject]@{ Allowed = $false; Reason = "Another model pull is already in progress - Airlock never starts parallel pulls." }
    }
    if ($RequiresConfirmation -and -not $UserConfirmed) {
        return [pscustomobject]@{ Allowed = $false; Reason = "This acquisition requires explicit user confirmation before downloading." }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = "Confirmed and no other pull in progress." }
}

# §6: "StopIfOwned: Stop only a process created by the current session and
# verified by PID start time plus instance nonce." Stricter than the
# existing PROXY-004 cmdline-only check (Start-ToolProxy.ps1) - every
# runtime adapter uses this, not a per-runtime reimplementation.
function Resolve-AirlockStopOwnership {
    param(
        [Parameter(Mandatory)][bool]$RecordedOwnerAlive,
        [Parameter(Mandatory)][bool]$PidMatches,
        [Parameter(Mandatory)][bool]$StartTimeMatches,
        [Parameter(Mandatory)][bool]$InstanceNonceMatches
    )
    if (-not $RecordedOwnerAlive) {
        return [pscustomobject]@{ Allowed = $false; Reason = "No live recorded owner - nothing this session started is running." }
    }
    if (-not ($PidMatches -and $StartTimeMatches -and $InstanceNonceMatches)) {
        return [pscustomobject]@{ Allowed = $false; Reason = "PID/start-time/instance-nonce do not all match the recorded owner - refusing to stop a process this session did not start." }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = "PID, start time, and instance nonce all match the recorded owner." }
}
