# Invoke-WorkspaceContract.ps1 — ADR-012 §7.2
# The derived-value workspace contract shared by every harness wrapper
# (Invoke-OpenCodeCapabilityContract.ps1 and friends in later phases): a
# disposable workspace, a random marker only the harness can read from
# seed.md, and an exact output.md assertion. §7.2: "each harness implements
# its own invocation wrapper" around this shared semantic test.
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by a dot-sourced file elsewhere in the chain reassigning the same name.
. (Join-Path $PSScriptRoot "agent-state-helpers.ps1")

function New-AirlockWorkspaceMarker {
    # 128-bit random value per §7.2 step 2. Never logged or included in the
    # prompt - only written to seed.md and compared against output.md.
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

# Pure: classify one trial's raw observations into pass/fail. §7.2: "A raw
# JSON tool object, a request for an external path, a plain-text fabricated
# tool request, absent output, or a tool-result-loop failure is a contract
# failure." None of these are partial passes - each is an unconditional fail.
function Resolve-AirlockWorkspaceTrialVerdict {
    param(
        [Parameter(Mandatory)][string]$ExpectedMarker,
        [string]$OutputContent,
        [Parameter(Mandatory)][bool]$ProcessSucceeded,
        [Parameter(Mandatory)][bool]$OutOfWorkspaceRequestDetected,
        [Parameter(Mandatory)][bool]$UsedValidStructuredToolEvents,
        [Parameter(Mandatory)][bool]$ToolResultLoopDetected
    )
    if (-not $ProcessSucceeded) {
        return [pscustomobject]@{ Passed = $false; Reason = "Harness process did not exit successfully." }
    }
    if ($OutOfWorkspaceRequestDetected) {
        return [pscustomobject]@{ Passed = $false; Reason = "Harness requested a path outside the disposable workspace." }
    }
    if (-not $UsedValidStructuredToolEvents) {
        return [pscustomobject]@{ Passed = $false; Reason = "No valid structured tool event observed - a raw JSON/plain-text tool-looking request is a contract failure, not partial credit." }
    }
    if ($ToolResultLoopDetected) {
        return [pscustomobject]@{ Passed = $false; Reason = "Tool-result loop detected." }
    }
    if ([string]::IsNullOrEmpty($OutputContent)) {
        return [pscustomobject]@{ Passed = $false; Reason = "output.md is absent or empty." }
    }
    if ($OutputContent -ne $ExpectedMarker) {
        return [pscustomobject]@{ Passed = $false; Reason = "output.md content does not exactly match the marker." }
    }
    return [pscustomobject]@{ Passed = $true; Reason = "Exact marker echoed; no boundary or tool-event violations." }
}

# Pure: the contract passes only after ALL trials pass (§7.2 step 7 + "The
# contract is a pass only after all trials pass").
function Resolve-AirlockWorkspaceContractVerdict {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$TrialResults)
    $failed = @($TrialResults | Where-Object { -not $_.Passed })
    if ($failed.Count -gt 0) {
        return [pscustomobject]@{ Passed = $false; Reason = "$($failed.Count) of $($TrialResults.Count) trial(s) failed." }
    }
    if ($TrialResults.Count -eq 0) {
        return [pscustomobject]@{ Passed = $false; Reason = "No trials were run." }
    }
    return [pscustomobject]@{ Passed = $true; Reason = "All $($TrialResults.Count) trials passed." }
}

# One real trial: disposable workspace + seed.md, delegate the actual
# harness invocation to the caller-supplied scriptblock (§7.3's per-harness
# wrapper), then assert and clean up. $Invoke receives ($WorkspacePath,
# $Marker) and must return a hashtable with the raw observations
# Resolve-AirlockWorkspaceTrialVerdict needs.
function Invoke-AirlockWorkspaceTrial {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][scriptblock]$Invoke
    )
    $marker = New-AirlockWorkspaceMarker
    $workspacePath = Join-Path $WorkspaceRoot ([guid]::NewGuid().ToString('N'))
    New-Item -Path $workspacePath -ItemType Directory -Force | Out-Null
    $started = [DateTime]::UtcNow
    try {
        Set-Content -Path (Join-Path $workspacePath "seed.md") -Value "MARKER=$marker" -Encoding utf8NoBOM -NoNewline

        $observations = & $Invoke $workspacePath $marker

        $outputPath = Join-Path $workspacePath "output.md"
        $outputContent = if (Test-Path $outputPath) { (Get-Content $outputPath -Raw).Trim() } else { $null }

        $verdict = Resolve-AirlockWorkspaceTrialVerdict -ExpectedMarker $marker -OutputContent $outputContent `
            -ProcessSucceeded $observations.ProcessSucceeded `
            -OutOfWorkspaceRequestDetected $observations.OutOfWorkspaceRequestDetected `
            -UsedValidStructuredToolEvents $observations.UsedValidStructuredToolEvents `
            -ToolResultLoopDetected $observations.ToolResultLoopDetected

        return [pscustomobject]@{
            Passed        = $verdict.Passed
            Reason        = $verdict.Reason
            LatencyMs     = ([DateTime]::UtcNow - $started).TotalMilliseconds
            SanitizedInfo = $observations.SanitizedInfo
        }
    } finally {
        Remove-Item -Path $workspacePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Full contract: 3 trials by default (§7.2 step 7).
function Invoke-AirlockWorkspaceContract {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][scriptblock]$Invoke,
        [int]$TrialCount = 3
    )
    $trials = 1..$TrialCount | ForEach-Object { Invoke-AirlockWorkspaceTrial -WorkspaceRoot $WorkspaceRoot -Invoke $Invoke }
    $verdict = Resolve-AirlockWorkspaceContractVerdict -TrialResults $trials
    return [pscustomobject]@{ Passed = $verdict.Passed; Reason = $verdict.Reason; Trials = $trials }
}
