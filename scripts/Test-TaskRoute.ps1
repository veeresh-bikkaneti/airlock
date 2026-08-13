# Self-check for Get-TaskRoute in Get-TaskRoute.ps1 - the ADR-006 advisory router behind
# ai-route/ai-handoff.
# Run: pwsh -File scripts/Test-TaskRoute.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "Get-TaskRoute.ps1") *> $null

$failures = 0
$Keywords = @("refactor", "migrate", "design", "architecture", "plan")

$cases = @(
    @{
        name = "rule 1: model can't tool-call wins even with a clean single-file task"
        args = @{ SupportsFunctionCalling = $false; Description = "fix a typo in README.md"; Keywords = $Keywords; FileCount = 1; MaxLineCount = 10 }
        expectRule = 1; expectDecision = "cloud"
    }
    @{
        name = "rule 1 wins over rule 3 even when file count AND line count also trip: bad model + multi-file must still land on rule 1, not rule 3"
        args = @{ SupportsFunctionCalling = $false; Description = "tweak logging"; Keywords = $Keywords; FileCount = 5; MaxLineCount = 2000 }
        expectRule = 1; expectDecision = "cloud"
    }
    @{
        name = "rule 2: planning keyword present, model can tool-call, scope is small"
        args = @{ SupportsFunctionCalling = $true; Description = "refactor the login module"; Keywords = $Keywords; FileCount = 1; MaxLineCount = 50 }
        expectRule = 2; expectDecision = "cloud"
    }
    @{
        name = "rule 2 wins over rule 3: keyword present even though scope also small (no rule-3 trip expected here, still confirms ordering)"
        args = @{ SupportsFunctionCalling = $true; Description = "design a new plan for the architecture migration"; Keywords = $Keywords; FileCount = 1; MaxLineCount = 10 }
        expectRule = 2; expectDecision = "cloud"
    }
    @{
        name = "rule 3: file count over the threshold, no keyword, model can tool-call"
        args = @{ SupportsFunctionCalling = $true; Description = "fix three unrelated bugs"; Keywords = $Keywords; FileCount = 3; MaxLineCount = 50 }
        expectRule = 3; expectDecision = "cloud"
    }
    @{
        name = "rule 3: largest touched file over ~800 lines, file count otherwise fine"
        args = @{ SupportsFunctionCalling = $true; Description = "fix a bug"; Keywords = $Keywords; FileCount = 1; MaxLineCount = 801 }
        expectRule = 3; expectDecision = "cloud"
    }
    @{
        name = "rule 4: single-file, scoped, no keyword, model supports tool calls -> local"
        args = @{ SupportsFunctionCalling = $true; Description = "fix a null check in api.ts"; Keywords = $Keywords; FileCount = 1; MaxLineCount = 120 }
        expectRule = 4; expectDecision = "local"
    }
    @{
        name = "rule 4: boundary values (exactly 2 files, exactly 800 lines) do not trip rule 3"
        args = @{ SupportsFunctionCalling = $true; Description = "small edit"; Keywords = $Keywords; FileCount = 2; MaxLineCount = 800 }
        expectRule = 4; expectDecision = "local"
    }
    @{
        name = "no keywords configured (empty list) never trips rule 2"
        args = @{ SupportsFunctionCalling = $true; Description = "refactor everything"; Keywords = @(); FileCount = 1; MaxLineCount = 10 }
        expectRule = 4; expectDecision = "local"
    }
)

foreach ($c in $cases) {
    $callArgs = $c.args
    $result = Get-TaskRoute @callArgs
    if ($result.Rule -ne $c.expectRule -or $result.Decision -ne $c.expectDecision) {
        Write-Host "FAIL: $($c.name) -> Rule=$($result.Rule) Decision=$($result.Decision) Reason=$($result.Reason)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($c.name)" -ForegroundColor Green
    }
}

if ($failures -gt 0) { exit 1 }
Write-Host ""
Write-Host "All task-route checks passed" -ForegroundColor Green
