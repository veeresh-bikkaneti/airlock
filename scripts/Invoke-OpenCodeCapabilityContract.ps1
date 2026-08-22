# Invoke-OpenCodeCapabilityContract.ps1 — ADR-012 §7.3
# "Run real `opencode run` with a session-owned staged config, selected
# model, and disposable workspace. Verify config correlation and restore
# global configuration transaction." Wires Invoke-AirlockWorkspaceContract
# (§7.2, generic) through Invoke-AirlockHarnessConfigTransaction (§8.1,
# OpenCode's global-config staging) with a real `opencode run` invocation.
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by a dot-sourced file elsewhere in the chain reassigning the same name.
. (Join-Path $PSScriptRoot "Invoke-WorkspaceContract.ps1")
. (Join-Path $PSScriptRoot "Invoke-HarnessConfigTransaction.ps1")

# BUG FOUND BY A LIVE RUN: this whole config shape was invented, never
# checked against opencode's real schema. opencode's actual config
# (confirmed via `opencode debug config` against a real install with a
# working Ollama provider already in ~/.opencode/opencode.json) nests
# custom endpoints under provider.<id>.options.{baseURL, apiKey} with an
# npm adapter id, and models under provider.<id>.models.<modelRef>; the
# top-level `model` field is "<providerId>/<modelRef>", matching the CLI's
# own `-m provider/model` format. There is no top-level `baseUrl`/`model`
# shortcut and no room for an arbitrary extra key - unknown top-level keys
# are an unverified risk against a schema-validated config, so the session
# correlation id rides inside the free-text apiKey (opencode passes it
# through as an opaque credential; Ollama itself ignores its value) instead
# of its own field.
$script:AirlockOpenCodeProviderId = "airlock"

# Builds the OpenCode global config content for one profile/endpoint. Pure
# string construction - kept separate from the transaction so its shape is
# directly assertable in a test without staging a real file.
function Get-OpenCodeStagedConfigContent {
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$EndpointUrl,
        [Parameter(Mandatory)][string]$SessionId
    )
    $models = [ordered]@{}
    $models[$ModelRef] = [ordered]@{ name = $ModelRef }

    $config = [ordered]@{
        '$schema' = "https://opencode.ai/config.json"
        provider  = [ordered]@{}
        model     = "$($script:AirlockOpenCodeProviderId)/$ModelRef"
    }
    $config.provider[$script:AirlockOpenCodeProviderId] = [ordered]@{
        npm     = "@ai-sdk/openai-compatible"
        name    = "Airlock (session-owned)"
        options = [ordered]@{
            baseURL = $EndpointUrl
            # Correlates a running opencode process back to the exact
            # transaction that staged its config (§8.1's "Verify config
            # correlation") - opencode/Ollama treat this as an opaque
            # bearer value, never validated or logged back to us.
            apiKey  = "airlock-session-$SessionId"
        }
        models  = $models
    }
    return ($config | ConvertTo-Json -Depth 6)
}

# One workspace trial's harness invocation: runs `opencode run` against the
# disposable workspace with the fixed §7.2 instruction, then classifies the
# raw observations. Requires a real OpenCode CLI + validated endpoint - see
# Test-OpenCodeCapabilityContract.ps1 for what is unit-tested (the config
# content and the config-transaction correlation via a mocked Run) versus
# what needs live hardware (§10.2).
# Pure, so the regex fix (BUG FOUND BY A LIVE RUN, see the call site) is
# directly assertable without a live opencode process.
function Test-AirlockOpenCodeRawToolEventInStdout {
    param([string]$Stdout)
    return [bool]($Stdout -match '(?m)^\s*\{"[a-zA-Z_]+"\s*:')
}

function Invoke-OpenCodeWorkspaceTrial {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$OpenCodeConfigPath,
        [Parameter(Mandatory)][string]$ModelRef,
        [int]$TimeoutSeconds = 120
    )
    $instruction = "Read seed.md. Create output.md containing exactly the value after MARKER=. Do not access files outside this workspace. Reply exactly DONE."

    # BUG FOUND BY A LIVE RUN: a global npm install puts both an extensionless
    # POSIX shell shim and an "opencode.cmd" batch shim on PATH. Start-Process
    # -FilePath "opencode" resolved to the extensionless one on Windows and
    # failed with "%1 is not a valid Win32 application" - it's not something
    # CreateProcess can launch directly. Prefer the .cmd shim explicitly;
    # fall back to whatever Get-Command's normal Application resolution finds
    # (e.g. a real opencode.exe, or the shell shim under WSL/git-bash).
    $opencodeCommand = Get-Command "opencode.cmd" -ErrorAction SilentlyContinue
    if (-not $opencodeCommand) { $opencodeCommand = Get-Command "opencode" -CommandType Application -ErrorAction SilentlyContinue }
    if (-not $opencodeCommand) { throw "opencode CLI not found on PATH." }

    # BUG FOUND BY A LIVE RUN: `opencode run` has no `--config` flag at all -
    # confirmed against `opencode run --help`. Passing one made its yargs
    # parser print usage text and exit 1 instead of running anything. The
    # config file (OpenCodeConfigPath, ~/.opencode/opencode.json) is picked
    # up automatically because it's opencode's own fixed config location -
    # Invoke-AirlockHarnessConfigTransaction stages/restores its content, the
    # CLI itself never points at it directly. What opencode's CLI DOES take
    # is `-m provider/model`, which must match the provider id and model key
    # Get-OpenCodeStagedConfigContent just staged. --auto is required for a
    # headless run: opencode's default is to prompt for tool-use permission
    # (write output.md, etc.), which would hang forever with no interactive
    # terminal attached. That's safe here specifically because the
    # instruction is fixed, the workspace is disposable, and the trial
    # verdict already fails closed on any out-of-workspace access.
    # BUG FOUND BY A LIVE RUN: -Wait blocks with no deadline. A hung `opencode
    # run` (this trial's own live test hit exactly this - cause still
    # undiagnosed, see the disclosed gap) held Invoke-AirlockHarnessConfigTransaction's
    # lock and left the REAL ~/.opencode/opencode.json staged with Airlock's
    # content forever, since nothing was left to run the transaction's restore
    # step. -PassThru without -Wait plus a manual WaitForExit(timeout) lets us
    # kill the process and fail the trial cleanly instead.
    # AGENT-004: --print-logs enables structured event logging; capture logs for
    # positive observation of tool-call/tool-result pairs, not absence inference.
    $proc = Start-Process -FilePath $opencodeCommand.Source `
        -ArgumentList @("run", "-m", "$($script:AirlockOpenCodeProviderId)/$ModelRef", "--auto", "--print-logs", $instruction) `
        -WorkingDirectory $WorkspacePath -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $WorkspacePath ".stdout.log") `
        -RedirectStandardError (Join-Path $WorkspacePath ".stderr.log")

    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    $timedOut = -not $exited
    if ($timedOut) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
    }

    $stdout = Get-Content (Join-Path $WorkspacePath ".stdout.log") -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content (Join-Path $WorkspacePath ".stderr.log") -Raw -ErrorAction SilentlyContinue
    $outOfWorkspace = [bool]($stdout -match '\.\.[\\/]' -or $stdout -match '[A-Za-z]:\\(?!.*airlock)')
    # AGENT-004: Positive observation of structured tool events. Look for actual
    # tool-call/tool-result sequences in logs (request-ID-correlated) rather than
    # inferring from absence of raw JSON. Both stdout and stderr may contain logs.
    $allOutput = "$stdout`n$stderr"
    $usedStructuredToolEvents = [bool]($allOutput -match '"type"\s*:\s*"tool-call"' -or $allOutput -match '"type"\s*:\s*"tool-result"')
    $toolLoop = [bool]($stdout -match '(?i)(retry|repeating).{0,40}(retry|repeating)')

    return @{
        ProcessSucceeded              = (-not $timedOut) -and ($proc.ExitCode -eq 0)
        OutOfWorkspaceRequestDetected = $outOfWorkspace
        UsedValidStructuredToolEvents = $usedStructuredToolEvents
        ToolResultLoopDetected        = $toolLoop
        SanitizedInfo                 = if ($timedOut) { "timedOut=true after ${TimeoutSeconds}s" } else { "exitCode=$($proc.ExitCode)" }
    }
}

function Invoke-AirlockOpenCodeCapabilityContract {
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$EndpointUrl,
        [Parameter(Mandatory)][string]$OpenCodeConfigPath,
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$TransactionDir,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )
    $sessionId = [guid]::NewGuid().ToString()
    $stagedContent = Get-OpenCodeStagedConfigContent -ModelRef $ModelRef -EndpointUrl $EndpointUrl -SessionId $sessionId

    $txnResult = Invoke-AirlockHarnessConfigTransaction -ConfigPath $OpenCodeConfigPath -StagedContent $stagedContent `
        -LockPath $LockPath -BackupDir $BackupDir -TransactionDir $TransactionDir `
        -Run {
            Invoke-AirlockWorkspaceContract -WorkspaceRoot $WorkspaceRoot -TrialCount 3 -Invoke {
                param($WorkspacePath, $Marker)
                Invoke-OpenCodeWorkspaceTrial -WorkspacePath $WorkspacePath -Marker $Marker -OpenCodeConfigPath $OpenCodeConfigPath -ModelRef $ModelRef
            }
        }

    return $txnResult.RunOutput
}
