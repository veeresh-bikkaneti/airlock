# Self-check for agent-openclaw-helpers.ps1 (ADR-012 §9.3, Phase G).
# Run: pwsh -File scripts/Test-AgentOpenClawHelpers.ps1
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "agent-openclaw-helpers.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing agent-openclaw-helpers.ps1..." -ForegroundColor Cyan

# --- Resolve-AirlockOpenClawOperatorAllowlist: exact match only ---

$allowedOperators = @('local-cli', 'local-dashboard')

$opExact = Resolve-AirlockOpenClawOperatorAllowlist -AllowedOperators $allowedOperators -RequestingOperator 'local-cli'
Assert-True ($opExact.Decision -eq 'Allowed') "an exact allowlisted operator is Allowed"

$opNotListed = Resolve-AirlockOpenClawOperatorAllowlist -AllowedOperators $allowedOperators -RequestingOperator 'random-slack-bot'
Assert-True ($opNotListed.Decision -eq 'Denied') "an operator not in the allowlist is Denied"

$opCaseVariant = Resolve-AirlockOpenClawOperatorAllowlist -AllowedOperators $allowedOperators -RequestingOperator 'Local-CLI'
Assert-True ($opCaseVariant.Decision -eq 'Denied') "a case-varied form of an allowed operator is Denied under case-sensitive exact match"

$opSubstring = Resolve-AirlockOpenClawOperatorAllowlist -AllowedOperators $allowedOperators -RequestingOperator 'local-cli-imposter'
Assert-True ($opSubstring.Decision -eq 'Denied') "a superstring of an allowed operator is Denied"

$opEmpty = Resolve-AirlockOpenClawOperatorAllowlist -AllowedOperators @() -RequestingOperator 'local-cli'
Assert-True ($opEmpty.Decision -eq 'Denied') "an empty allowlist denies everything"

# --- Resolve-AirlockOpenClawJobTemplateGate: exact match only ---

$approvedTemplates = @('fixture-smoke-test', 'lint-only')

$tplExact = Resolve-AirlockOpenClawJobTemplateGate -ApprovedJobTemplates $approvedTemplates -RequestedJobTemplate 'fixture-smoke-test'
Assert-True ($tplExact.Decision -eq 'Allowed') "an exact pre-approved template is Allowed"

$tplUnapproved = Resolve-AirlockOpenClawJobTemplateGate -ApprovedJobTemplates $approvedTemplates -RequestedJobTemplate 'deploy-to-prod'
Assert-True ($tplUnapproved.Decision -eq 'Denied') "an unapproved/ad-hoc template is Denied"

$tplCaseVariant = Resolve-AirlockOpenClawJobTemplateGate -ApprovedJobTemplates $approvedTemplates -RequestedJobTemplate 'Fixture-Smoke-Test'
Assert-True ($tplCaseVariant.Decision -eq 'Denied') "a case-varied template id is Denied under case-sensitive exact match"

# --- Resolve-AirlockOpenClawContextCeiling: measured profile context is the
# ceiling, never the model card max or a high-context tier ---

$ctxUnderCeiling = Resolve-AirlockOpenClawContextCeiling -MeasuredProfileContext 8192 -RequestedContext 4096
Assert-True ($ctxUnderCeiling.Decision -eq 'Allowed' -and $ctxUnderCeiling.EffectiveContext -eq 4096) "a request under the measured ceiling passes through unchanged"

$ctxAtCeiling = Resolve-AirlockOpenClawContextCeiling -MeasuredProfileContext 8192 -RequestedContext 8192
Assert-True ($ctxAtCeiling.Decision -eq 'Allowed' -and $ctxAtCeiling.EffectiveContext -eq 8192) "a request exactly at the measured ceiling is Allowed, not clamped"

$ctxOverCeiling = Resolve-AirlockOpenClawContextCeiling -MeasuredProfileContext 8192 -RequestedContext 128000
Assert-True ($ctxOverCeiling.Decision -eq 'Clamped' -and $ctxOverCeiling.EffectiveContext -eq 8192) "a request far above the measured ceiling (e.g. a model-card 'high-context tier') is Clamped down to the measured value, never honored at the higher value"

try {
    Resolve-AirlockOpenClawContextCeiling -MeasuredProfileContext 0 -RequestedContext 4096 | Out-Null
    Assert-True $false "a zero/unmeasured MeasuredProfileContext should throw, never silently authorize a ceiling"
} catch {
    Assert-True $true "a zero MeasuredProfileContext throws"
}

try {
    Resolve-AirlockOpenClawContextCeiling -MeasuredProfileContext 8192 -RequestedContext 0 | Out-Null
    Assert-True $false "a zero/negative RequestedContext should throw"
} catch {
    Assert-True $true "a zero RequestedContext throws"
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures agent-openclaw-helpers check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All agent-openclaw-helpers checks passed" -ForegroundColor Green
exit 0
