# Get-TaskRoute.ps1 — pure decision cascade behind ai-route/ai-handoff (ADR-006).
# No file I/O, no network — same reason Get-ModelSizingCeilingGB was extracted out of
# Start-AI.ps1 (see scripts/Get-ModelAcquisition.ps1): callers do the reading, this just
# decides, so it stays directly testable (see Test-TaskRoute.ps1).

function Get-TaskRoute {
    # 4-rule cascade, first match wins, exactly as ADR-006's Decision section orders them:
    #   1. model can't tool-call            -> cloud
    #   2. planning/architecture keyword     -> cloud
    #   3. multi-file or large-file scope    -> cloud
    #   4. otherwise                         -> local
    param(
        [Parameter(Mandatory)][bool]$SupportsFunctionCalling,
        [Parameter(Mandatory)][string]$Description,
        [string[]]$Keywords = @(),
        [int]$FileCount = 0,
        [int]$MaxLineCount = 0
    )

    if (-not $SupportsFunctionCalling) {
        return [pscustomobject]@{
            Decision = 'cloud'
            Reason   = "active model can't reliably tool-call."
            Rule     = 1
        }
    }

    # -match is case-insensitive by default; a plain substring check is enough here — ADR-006
    # doesn't ask for whole-word matching, just "presence of" a keyword in the description.
    $matched = $Keywords | Where-Object { $_ -and ($Description -match [regex]::Escape($_)) } | Select-Object -First 1
    if ($matched) {
        return [pscustomobject]@{
            Decision = 'cloud'
            Reason   = "task needs planning, not just editing."
            Rule     = 2
        }
    }

    if ($FileCount -gt 2 -or $MaxLineCount -gt 800) {
        return [pscustomobject]@{
            Decision = 'cloud'
            Reason   = "multi-file or large-file scope."
            Rule     = 3
        }
    }

    return [pscustomobject]@{
        Decision = 'local'
        Reason   = "single-file, scoped, model supports tool calls."
        Rule     = 4
    }
}
