# agent-openclaw-helpers.ps1 — ADR-012 §9.3 "OpenClaw coordinator adapter" (Phase G)
# Pure decision functions for the OpenClaw job-dispatch path: operator
# allowlist, job-template gate, and model-context ceiling. Same convention as
# agent-job-helpers.ps1/agent-profile-helpers.ps1 - no runtime/Docker/git I/O
# here, so every rule is testable without live OpenClaw, Docker, or a model
# server. See Test-AgentOpenClawHelpers.ps1 and
# scripts/Invoke-OpenClawJobDispatch.ps1 (the orchestrator that wires these
# into a real job-manifest write + scripts/Start-AgentWorkerJob.ps1 handoff).
#
# §9.3: "Its adapter may create a job manifest only from an allowlisted local
# operator/channel and only for pre-approved job templates. It has no direct
# file-write, shell, secret, Git remote, or worker-container privilege."

# Same rigor as Resolve-AirlockCommandAllowlist (agent-job-helpers.ps1):
# exact match only, case-sensitive (-ccontains). An operator/channel name is
# a literal identifier, not a case-insensitive display string or a prefix to
# fuzzy-match against.
function Resolve-AirlockOpenClawOperatorAllowlist {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AllowedOperators,
        [Parameter(Mandatory)][string]$RequestingOperator
    )
    if ($AllowedOperators -ccontains $RequestingOperator) {
        return [pscustomobject]@{ Decision = 'Allowed'; Reason = "Exact (case-sensitive) match against the allowlisted local operator/channel list." }
    }
    return [pscustomobject]@{ Decision = 'Denied'; Reason = "'$RequestingOperator' is not an exact (case-sensitive) match in the allowlisted operator/channel list. OpenClaw never dispatches on behalf of an unlisted or fuzzy-matched operator." }
}

# §9.3: "only for pre-approved job templates". Exact match only - a job
# template id is a fixed, source-controlled identifier; it is never
# substring/prefix matched, and an unrecognized template never triggers a
# job regardless of any other field on the request.
function Resolve-AirlockOpenClawJobTemplateGate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ApprovedJobTemplates,
        [Parameter(Mandatory)][string]$RequestedJobTemplate
    )
    if ($ApprovedJobTemplates -ccontains $RequestedJobTemplate) {
        return [pscustomobject]@{ Decision = 'Allowed'; Reason = "Exact (case-sensitive) match against the pre-approved job-template list." }
    }
    return [pscustomobject]@{ Decision = 'Denied'; Reason = "'$RequestedJobTemplate' is not an exact match in the pre-approved job-template list. Only a pre-approved template may trigger a job - nothing is dispatched from an unapproved or ad-hoc template." }
}

# §9.3: "The effective model context is the measured profile context - not
# the model card's maximum or OpenClaw's recommended high-context tier."
# Never widens: a request at or under the measured ceiling passes through
# unchanged; anything above it is clamped down to the measured ceiling, never
# rejected outright and never honored at the higher value.
function Resolve-AirlockOpenClawContextCeiling {
    param(
        [Parameter(Mandatory)][int]$MeasuredProfileContext,
        [Parameter(Mandatory)][int]$RequestedContext
    )
    if ($MeasuredProfileContext -le 0) { throw "MeasuredProfileContext must be positive - a profile without a measured, proven context can never authorize an OpenClaw context ceiling." }
    if ($RequestedContext -le 0) { throw "RequestedContext must be positive." }

    if ($RequestedContext -le $MeasuredProfileContext) {
        return [pscustomobject]@{
            Decision         = 'Allowed'
            EffectiveContext = $RequestedContext
            Reason           = "Requested context ($RequestedContext) does not exceed the measured profile context ($MeasuredProfileContext)."
        }
    }
    return [pscustomobject]@{
        Decision         = 'Clamped'
        EffectiveContext = $MeasuredProfileContext
        Reason           = "Requested context ($RequestedContext) exceeds the measured profile context ($MeasuredProfileContext) - clamped down to the measured value. Never widened to the model card's maximum or OpenClaw's recommended high-context tier."
    }
}
