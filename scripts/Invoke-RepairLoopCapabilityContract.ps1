# Invoke-RepairLoopCapabilityContract.ps1 — ADR-012 AGENT-005
# Real repair-loop signal: two bash tool_use events (part.tool=='bash', status=='completed')
# with Test-*.ps1 commands, first emitting FAIL output, then "All checks passed".
. (Join-Path $PSScriptRoot "Invoke-WorkspaceContract.ps1")
. (Join-Path $PSScriptRoot "Invoke-HarnessConfigTransaction.ps1")

# Pure function: parse tool_use events, detect repair-loop signals.
function Resolve-AirlockRepairLoopVerdict {
    param([Parameter(Mandatory)][string[]]$StdoutLines, [string]$WorkspacePath = "")

    $bashToolEvents = @()
    $usedStructuredToolEvents = $false
    $outOfWorkspace = $false
    $testFailureDetected = $false
    $testPassDetected = $false

    if ($WorkspacePath) {
        $normalizedWorkspacePath = [System.IO.Path]::GetFullPath($WorkspacePath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    }

    foreach ($line in $StdoutLines) {
        try {
            $json = $line | ConvertFrom-Json
            # Positive: tool_use, completed, not invalid.
            if ($json.type -eq 'tool_use' -and $json.part.type -eq 'tool' -and $json.part.state.status -eq 'completed' -and $json.part.tool -ne 'invalid') {
                $usedStructuredToolEvents = $true

                # Capture bash-tool test runs (real tool output).
                if ($json.part.tool -eq 'bash' -and $json.part.state.input.command -match 'Test-') {
                    $output = $json.part.state.output
                    $bashToolEvents += @{
                        Command = $json.part.state.input.command
                        Output  = $output
                        CallId  = $json.part.callID
                        HasFail = $output -match '(?m)^FAIL:'
                        HasPass = $output -match '(?m)^All checks passed'
                    }
                    if ($output -match '(?m)^FAIL:') { $testFailureDetected = $true }
                    if ($output -match '(?m)^All checks passed') { $testPassDetected = $true }
                }

                # Workspace containment (write tool only).
                if ($WorkspacePath -and $json.part.tool -eq 'write' -and $json.part.state.metadata.filepath) {
                    $filepath = $json.part.state.metadata.filepath
                    if ([System.IO.Path]::IsPathRooted($filepath)) {
                        $normalizedFilepath = [System.IO.Path]::GetFullPath($filepath)
                    } else {
                        $normalizedFilepath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($WorkspacePath, $filepath))
                    }
                    $normalizedFilepath = $normalizedFilepath.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
                    if (-not $normalizedFilepath.StartsWith($normalizedWorkspacePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $outOfWorkspace = $true
                    }
                }
            }
        } catch { }
    }

    $repairLoopSucceeded = $testFailureDetected -and $testPassDetected -and ($bashToolEvents.Count -ge 2)

    return [pscustomobject]@{
        RepairLoopSucceeded           = $repairLoopSucceeded
        TestFailureDetected           = $testFailureDetected
        TestPassDetected              = $testPassDetected
        BashToolEvents                = $bashToolEvents
        UsedStructuredToolEvents      = $usedStructuredToolEvents
        OutOfWorkspaceRequestDetected = $outOfWorkspace
    }
}

function Invoke-RepairLoopWorkspaceTrial {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$SpecContent,
        [Parameter(Mandatory)][bool]$ColdStart,
        [Parameter(Mandatory)][string]$OpenCodeConfigPath,
        [Parameter(Mandatory)][string]$ModelRef,
        [int]$TimeoutSeconds = 120
    )
    $instruction = "Read spec.md. Follow the task exactly."

    $opencodeCommand = Get-Command "opencode.cmd" -ErrorAction SilentlyContinue
    if (-not $opencodeCommand) { $opencodeCommand = Get-Command "opencode" -CommandType Application -ErrorAction SilentlyContinue }
    if (-not $opencodeCommand) { throw "opencode CLI not found on PATH." }

    $proc = Start-Process -FilePath $opencodeCommand.Source `
        -ArgumentList @("run", "-m", "airlock/$ModelRef", "--auto", "--format", "json", $instruction) `
        -WorkingDirectory $WorkspacePath -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $WorkspacePath ".stdout.log") `
        -RedirectStandardError (Join-Path $WorkspacePath ".stderr.log")

    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    $timedOut = -not $exited
    if ($timedOut) { try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { } }

    $stdout = Get-Content (Join-Path $WorkspacePath ".stdout.log") -Raw -ErrorAction SilentlyContinue
    $stdoutLines = @($stdout -split "`n" | Where-Object { $_.Trim() })

    # Call pure classification logic.
    $verdict = Resolve-AirlockRepairLoopVerdict -StdoutLines $stdoutLines -WorkspacePath $WorkspacePath

    return @{
        ProcessSucceeded              = (-not $timedOut) -and ($proc.ExitCode -eq 0)
        OutOfWorkspaceRequestDetected = $verdict.OutOfWorkspaceRequestDetected
        UsedValidStructuredToolEvents = $verdict.UsedStructuredToolEvents
        RepairLoopSucceeded           = $verdict.RepairLoopSucceeded
        TestFailureDetected           = $verdict.TestFailureDetected
        TestPassDetected              = $verdict.TestPassDetected
        BashToolEvents                = $verdict.BashToolEvents
        SanitizedInfo                 = if ($timedOut) { "timedOut=true" } else { "exitCode=$($proc.ExitCode)" }
    }
}

function Invoke-AirlockRepairLoopCapabilityContract {
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$EndpointUrl,
        [Parameter(Mandatory)][string]$OpenCodeConfigPath,
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$TransactionDir,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$SpecContent,
        [string]$FixtureDir = ""
    )
    $sessionId = [guid]::NewGuid().ToString()
    $stagedContent = Get-OpenCodeStagedConfigContent -ModelRef $ModelRef -EndpointUrl $EndpointUrl -SessionId $sessionId

    $txnResult = Invoke-AirlockHarnessConfigTransaction -ConfigPath $OpenCodeConfigPath -StagedContent $stagedContent `
        -LockPath $LockPath -BackupDir $BackupDir -TransactionDir $TransactionDir `
        -Run {
            Invoke-AirlockRepairLoopContract -WorkspaceRoot $WorkspaceRoot -SpecContent $SpecContent -FixtureDir $FixtureDir -Invoke {
                param($WorkspacePath, $SpecContent, $ColdStart)
                $result = Invoke-RepairLoopWorkspaceTrial -WorkspacePath $WorkspacePath -SpecContent $SpecContent `
                    -ColdStart $ColdStart -OpenCodeConfigPath $OpenCodeConfigPath -ModelRef $ModelRef
                return @{
                    Passed                        = $result.RepairLoopSucceeded
                    Reason                        = "Fail: $($result.TestFailureDetected), Pass: $($result.TestPassDetected), Events: $($result.BashToolEvents.Count)"
                    StructuredTrace               = $result.BashToolEvents
                    RepairApplied                 = $result.RepairLoopSucceeded
                    UsedValidStructuredToolEvents = $result.UsedValidStructuredToolEvents
                }
            }
        }

    return $txnResult.RunOutput
}

function Get-OpenCodeStagedConfigContent {
    param([Parameter(Mandatory)][string]$ModelRef,[Parameter(Mandatory)][string]$EndpointUrl,[Parameter(Mandatory)][string]$SessionId)
    $script:AirlockOpenCodeProviderId="airlock"
    $models=[ordered]@{};$models[$ModelRef]=[ordered]@{name=$ModelRef}
    $config=[ordered]@{'$schema'="https://opencode.ai/config.json";provider=[ordered]@{};model="$($script:AirlockOpenCodeProviderId)/$ModelRef"}
    $config.provider[$script:AirlockOpenCodeProviderId]=[ordered]@{npm="@ai-sdk/openai-compatible";name="Airlock";options=[ordered]@{baseURL=$EndpointUrl;apiKey="airlock-session-$SessionId"};models=$models}
    return ($config|ConvertTo-Json -Depth 6)
}
