# cloud-guard.ps1 — decide whether a paid fallback is allowed.
# This function does not call the network. A 402 or 429 stops the run.
# The fallback is local, which costs nothing. It does not escalate to a
# more expensive provider after the cheap one fails.

function Resolve-AirlockCloudDecision {
    param(
        [bool]$Enabled,
        [bool]$AllowSensitive,
        [bool]$Sensitive,
        [int]$MaxAttempts,
        [double]$MaxCostUsd,
        [int]$TimeoutSec,
        [int]$AttemptsMade,
        [double]$SpentUsd,
        [string]$LastHttpStatus = '',
        [bool]$CircuitOpen,
        [string[]]$ProvidersInCostOrder = @(),
        [hashtable]$AttemptCostUsd = @{}
    )

    $stop = {
        param($Reason, [bool]$Trip)
        [pscustomobject]@{
            Allow = $false; Provider = $null; TimeoutSec = 0; EstimatedUsd = 0
            CircuitOpen = $Trip; Fallback = 'local'; Reason = $Reason
        }
    }

    $limitsOk = ($MaxAttempts -ge 1 -and $MaxAttempts -le 3) -and
        [double]::IsFinite($MaxCostUsd) -and ($MaxCostUsd -gt 0) -and
        ($TimeoutSec -ge 1 -and $TimeoutSec -le 30) -and
        [double]::IsFinite($SpentUsd) -and ($SpentUsd -ge 0) -and
        ($AttemptsMade -ge 0)
    if (-not $limitsOk) { return & $stop 'invalid guard: attempts must be 1-3, timeout 1-30s, budget a positive finite USD amount' $CircuitOpen }
    if (-not $Enabled) { return & $stop 'cloud disabled; stay on the local runtime' $false }
    if ($Sensitive -and -not $AllowSensitive) { return & $stop 'sensitive request stays local' $false }
    if ($CircuitOpen -or $LastHttpStatus -in @('402', '429')) {
        return & $stop "circuit open after HTTP $LastHttpStatus; no further paid call" $true
    }
    if ($AttemptsMade -ge $MaxAttempts) { return & $stop "retry cap $MaxAttempts reached" $CircuitOpen }
    if ($SpentUsd -ge $MaxCostUsd) { return & $stop "budget $$MaxCostUsd already spent" $true }

    foreach ($name in @($ProvidersInCostOrder)) {
        if (-not $AttemptCostUsd.ContainsKey($name)) { continue }
        $cost = [double]$AttemptCostUsd[$name]
        if (-not [double]::IsFinite($cost) -or $cost -lt 0) { continue }
        if (($SpentUsd + $cost) -gt $MaxCostUsd) { continue }
        return [pscustomobject]@{
            Allow = $true; Provider = $name; TimeoutSec = $TimeoutSec; EstimatedUsd = $cost
            CircuitOpen = $false; Fallback = $null
            Reason = "one attempt on $name, ceiling `$$cost, timeout ${TimeoutSec}s, spent `$$SpentUsd of `$$MaxCostUsd"
        }
    }
    return & $stop 'next paid attempt would exceed the budget; stay local' $true
}
