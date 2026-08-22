# Invoke-PiCapabilityContract.ps1 — ADR-012 §7.3
# "Run Pi in a disposable workspace against the exact OpenAI-compatible
# endpoint; prove one read/write/tool-result loop." Wires
# Invoke-AirlockWorkspaceContract (§7.2, generic) with a Pi-specific
# container invocation. Unlike Invoke-OpenCodeCapabilityContract.ps1, this
# wrapper does not go through Invoke-HarnessConfigTransaction.ps1: Pi
# receives its endpoint/model via env vars into a disposable container
# (§8.2), not a global config file that needs staging/backup/restore, so
# there is no global-config transaction here for that machinery to protect.
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being
# clobbered by a dot-sourced file elsewhere in the chain reassigning the
# same name.
. (Join-Path $PSScriptRoot "Invoke-WorkspaceContract.ps1")

# Builds the `docker run` argument list for one Pi capability trial. Pure -
# kept separate from the actual invocation so the exact endpoint/model
# wiring is directly assertable in a test without a real Docker/Pi install
# (see Test-PiCapabilityContract.ps1 and §10.2). The workspace is bind-
# mounted read-write at /workspace (unlike run-hermes.ps1's real-session
# read-only repo mount via docker-compose.yml) because this trial's whole
# point is proving Pi can write output.md back into it.
function Get-PiContainerRunArgs {
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$EndpointUrl,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$Instruction,
        [string]$ImageName = "hermes-container-hermes-agent"
    )
    $port = ([uri]$EndpointUrl).Port
    return @(
        "run", "--rm",
        "-v", "${WorkspacePath}:/workspace",
        "-e", "OLLAMA_HOST=host.docker.internal:$port",
        "-e", "OPENAI_API_KEY=ollama",
        "-e", "OPENAI_BASE_URL=http://host.docker.internal:$port/v1",
        "-e", "AIRLOCK_MODEL=$ModelRef",
        "--add-host", "host.docker.internal:host-gateway",
        $ImageName,
        "pi", "--provider", "ollama-local", "--model", $ModelRef, "--prompt", $Instruction
    )
}

# Pure: classify one trial's raw Pi container stdout/exit code into the
# observations Resolve-AirlockWorkspaceTrialVerdict needs. Kept separate
# from the actual container invocation so it's directly testable without
# Docker (see Test-PiCapabilityContract.ps1). Pi runs inside a Linux
# container (unlike OpenCode's native-Windows path), so an out-of-
# workspace request looks like an absolute POSIX path outside /workspace
# (e.g. /etc/passwd, /home/hermes/...), not a Windows drive letter -
# reusing OpenCode's Windows-path regex here would make §7.2's
# out-of-workspace assertion permanently unable to fire for Pi.
# AGENT-004: Positive observation of structured tool events from both stdout
# and stderr, not negative inference from absence. Look for actual tool-call
# and tool-result event markers in the captured output.
function Resolve-AirlockPiTrialObservations {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Stdout = '',
        [AllowEmptyString()][string]$Stderr = ''
    )
    # Relative parent traversal (either path style) or an absolute POSIX
    # path whose first segment isn't "workspace" - /workspace and
    # /workspace/... are the disposable mount itself, not an escape.
    $outOfWorkspace = [bool]($Stdout -match '\.\.[\\/]' -or $Stdout -match '(?<!\S)/(?!workspace(?:/|\b))\S+')
    # AGENT-004: Positive observation of actual JSON events from container logs.
    # Pi runs in Docker; event stream may come from stdout or stderr. Check both.
    $usedStructuredToolEvents = $false
    $allLines = @(($Stdout + "`n" + $Stderr) -split "`n" | Where-Object { $_.Trim() })
    foreach ($line in $allLines) {
        try {
            $json = $line | ConvertFrom-Json
            if ($json.type -match 'tool') { $usedStructuredToolEvents = $true; break }
        } catch { }
    }
    $toolLoop = [bool]($Stdout -match '(?i)(retry|repeating).{0,40}(retry|repeating)')

    return @{
        ProcessSucceeded              = ($ExitCode -eq 0)
        OutOfWorkspaceRequestDetected = $outOfWorkspace
        UsedValidStructuredToolEvents = $usedStructuredToolEvents
        ToolResultLoopDetected        = $toolLoop
        SanitizedInfo                 = "exitCode=$ExitCode"
    }
}

# One workspace trial's harness invocation: runs the Pi container against
# the disposable workspace with the fixed §7.2 instruction, then
# classifies the raw observations. Requires a real Docker install + built
# hermes-agent image + a validated, reachable Ollama endpoint - not
# exercised by the unit suite (§10.2 live acceptance gate; this
# environment has neither Docker nor a live Ollama to prove it against).
function Invoke-PiWorkspaceTrial {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$EndpointUrl,
        [string]$ImageName = "hermes-container-hermes-agent"
    )
    $instruction = "Read seed.md. Create output.md containing exactly the value after MARKER=. Do not access files outside this workspace. Reply exactly DONE."
    $runArgs = Get-PiContainerRunArgs -ModelRef $ModelRef -EndpointUrl $EndpointUrl -WorkspacePath $WorkspacePath -Instruction $instruction -ImageName $ImageName

    $proc = Start-Process -FilePath "docker" -ArgumentList $runArgs `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $WorkspacePath ".stdout.log") `
        -RedirectStandardError (Join-Path $WorkspacePath ".stderr.log")

    $stdout = Get-Content (Join-Path $WorkspacePath ".stdout.log") -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content (Join-Path $WorkspacePath ".stderr.log") -Raw -ErrorAction SilentlyContinue
    return Resolve-AirlockPiTrialObservations -ExitCode $proc.ExitCode -Stdout $stdout -Stderr $stderr
}

function Invoke-AirlockPiCapabilityContract {
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$EndpointUrl,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$ImageName = "hermes-container-hermes-agent"
    )
    return Invoke-AirlockWorkspaceContract -WorkspaceRoot $WorkspaceRoot -TrialCount 3 -Invoke {
        param($WorkspacePath, $Marker)
        Invoke-PiWorkspaceTrial -WorkspacePath $WorkspacePath -Marker $Marker -ModelRef $ModelRef -EndpointUrl $EndpointUrl -ImageName $ImageName
    }
}
