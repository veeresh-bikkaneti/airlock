# agent-fail-ledger.ps1 — the vision's "self-improve in-repo, not magic AGI"
# (docs/10-Product-Vision.md): "logs, certificates, fail ledgers, and honest
# step-downs so the platform gets smarter about *this hardware* over time."
#
# The capability registry (agent-capability-registry.ps1) is a short-TTL cache
# - pass entries live 5 minutes, fail entries 1 minute - so it deliberately
# forgets. The fail ledger is the long memory: an append-only JSONL file of
# contract failures keyed by profile+harness. The next ai-agent-start on this
# hardware reads it before spending minutes re-proving a combination that
# already failed here, and warns instead of rediscovering the failure.
#
# Ledger entries are diagnostic, never authoritative: a ledger hit warns, it
# never refuses. Refusal stays where the vision puts it - "refuse only when
# even mmap won't fit" - a past failure is a reason to look closer, not a
# verdict about this run.
$script:AirlockFailLedgerMaxReasonChars = 500

# Append one failure entry. Never throws - the ledger is auxiliary; a failure
# to record must never break the session it is observing.
function Write-AirlockFailLedgerEntry {
    param(
        [Parameter(Mandatory)][string]$LedgerPath,
        [Parameter(Mandatory)][string]$ProfileId,
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][string]$Harness,
        [string]$EvidenceKey = '',
        [string]$Reason = ''
    )
    try {
        $dir = Split-Path -Parent $LedgerPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $boundedReason = if ($Reason.Length -gt $script:AirlockFailLedgerMaxReasonChars) {
            $Reason.Substring(0, $script:AirlockFailLedgerMaxReasonChars)
        } else { $Reason }
        $entry = [ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            host         = $env:COMPUTERNAME
            profileId    = $ProfileId
            modelRef     = $ModelRef
            runtime      = $Runtime
            harness      = $Harness
            evidenceKey  = $EvidenceKey
            reason       = $boundedReason
        }
        ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LedgerPath -Encoding utf8
        return [pscustomobject]@{ Recorded = $true; Entry = $entry }
    } catch {
        return [pscustomobject]@{ Recorded = $false; Reason = $_.Exception.Message }
    }
}

# Summarize past failures for one profile+harness pair on this ledger.
# Pure read - safe to call before any run. Returns a zero-count summary when
# the ledger is absent or has no matching entries, never $null.
function Get-AirlockFailLedgerSummary {
    param(
        [Parameter(Mandatory)][string]$LedgerPath,
        [Parameter(Mandatory)][string]$ProfileId,
        [Parameter(Mandatory)][string]$Harness
    )
    $summary = [pscustomobject]@{ Count = 0; LastAt = ''; LastReason = '' }
    if (-not (Test-Path $LedgerPath)) { return $summary }
    try {
        $count = 0
        $lastAt = ''
        $lastReason = ''
        Get-Content -Path $LedgerPath -ErrorAction Stop | ForEach-Object {
            $line = $_.Trim()
            if (-not $line) { return }
            try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { return }
            if ($e.profileId -eq $ProfileId -and $e.harness -eq $Harness) {
                $count++
                if ($e.timestampUtc) { $lastAt = [string]$e.timestampUtc }
                if ($e.reason) { $lastReason = [string]$e.reason }
            }
        }
        $summary.Count = $count
        $summary.LastAt = $lastAt
        $summary.LastReason = $lastReason
    } catch { }
    return $summary
}

# Pure: format the startup warning for a non-empty summary. Returns $null when
# there is nothing to warn about, so callers can branch on its presence.
function Resolve-AirlockFailLedgerWarning {
    param(
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)][string]$ProfileId,
        [Parameter(Mandatory)][string]$Harness
    )
    if ($Summary.Count -le 0) { return $null }
    $times = if ($Summary.Count -eq 1) { 'once' } else { "$($Summary.Count) times" }
    $warning = "profile '$ProfileId' + harness '$Harness' failed $times before on this hardware"
    if ($Summary.LastAt) { $warning += " (last: $($Summary.LastAt)" }
    else { $warning += " (" }
    if ($Summary.LastReason) { $warning += "; $($Summary.LastReason)" }
    $warning += "). Past failure is not this run's verdict - re-proving now."
    return $warning
}
