# Invoke-RepairLoopCapabilityContract.ps1 — ADR-012 AGENT-005
# Repair-loop capability test: read spec → break test → run allowlisted test →
# parse failure → apply one repair → rerun to pass. 3 cold + 3 warm trials
# with structured trace capture each round.
. (Join-Path $PSScriptRoot "Invoke-WorkspaceContract.ps1")
. (Join-Path $PSScriptRoot "Invoke-HarnessConfigTransaction.ps1")

# One repair-loop trial: read spec, intentionally break, run tests, parse,
# repair, re-run. Delegate actual execution to caller-supplied scriptblock.
function Invoke-RepairLoopWorkspaceTrial {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$SpecContent,
        [Parameter(Mandatory)][bool]$ColdStart,
        [Parameter(Mandatory)][string]$OpenCodeConfigPath,
        [Parameter(Mandatory)][string]$ModelRef,
        [int]$TimeoutSeconds = 120
    )
    # Spec format: BREAK=<component> TEST=<allowlisted> REPAIR=<hint>
    # Example: BREAK=math-service TEST=calc-unit REPAIR=operator
    $specLines = $SpecContent -split "`n" | Where-Object { $_ -match '=' }
    $spec = @{}
    $specLines | ForEach-Object {
        $key, $value = $_ -split '=', 2
        $spec[$key.Trim()] = $value.Trim()
    }

    # Instruction: intentionally introduce the break, run tests, auto-repair.
    $instruction = @"
Read spec.md. Intentionally break `$($spec['BREAK']).
Run `$($spec['TEST']) test. Parse failure. Apply one `$($spec['REPAIR']) repair.
Re-run test to verify pass. Return PASS or FAIL.
"@

    # Similar to OpenCode trial: run with --format json, capture structured trace.
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

    # Collect structured trace: atomic tool_use events with request-ID (callID).
    $structuredTrace = @()
    $normalizedWorkspacePath = [System.IO.Path]::GetFullPath($WorkspacePath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $stdoutLines = @($stdout -split "`n" | Where-Object { $_.Trim() })

    $usedStructuredToolEvents = $false
    $outOfWorkspace = $false

    foreach ($line in $stdoutLines) {
        try {
            $json = $line | ConvertFrom-Json
            if ($json.type -eq 'tool_use' -and $json.part.type -eq 'tool' -and $json.part.state.status -eq 'completed') {
                $usedStructuredToolEvents = $true
                # Capture trace with callID for request-ID correlation.
                $structuredTrace += [pscustomobject]@{
                    Type      = $json.type
                    Tool      = $json.part.tool
                    CallId    = $json.part.callID
                    Status    = $json.part.state.status
                    Timestamp = $json.timestamp
                }
                # Check workspace containment.
                if ($json.part.state.metadata.filepath) {
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

    # Parse pass/fail from stdout (look for PASS or FAIL).
    $testPassed = [bool]($stdout -match '(?i)pass')
    $testFailed = [bool]($stdout -match '(?i)fail')
    $repairApplied = [bool]($stdout -match '(?i)(repair|fix)')

    return @{
        ProcessSucceeded              = (-not $timedOut) -and ($proc.ExitCode -eq 0)
        OutOfWorkspaceRequestDetected = $outOfWorkspace
        UsedValidStructuredToolEvents = $usedStructuredToolEvents
        TestPassed                    = $testPassed
        TestFailed                    = $testFailed
        RepairApplied                 = $repairApplied
        StructuredTrace               = $structuredTrace
        SanitizedInfo                 = if ($timedOut) { "timedOut=true after ${TimeoutSeconds}s" } else { "exitCode=$($proc.ExitCode)" }
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
        [Parameter(Mandatory)][string]$SpecContent
    )
    $sessionId = [guid]::NewGuid().ToString()
    $stagedContent = Get-OpenCodeStagedConfigContent -ModelRef $ModelRef -EndpointUrl $EndpointUrl -SessionId $sessionId

    $txnResult = Invoke-AirlockHarnessConfigTransaction -ConfigPath $OpenCodeConfigPath -StagedContent $stagedContent `
        -LockPath $LockPath -BackupDir $BackupDir -TransactionDir $TransactionDir `
        -Run {
            Invoke-AirlockRepairLoopContract -WorkspaceRoot $WorkspaceRoot -SpecContent $SpecContent -Invoke {
                param($WorkspacePath, $SpecContent, $ColdStart)
                $result = Invoke-RepairLoopWorkspaceTrial -WorkspacePath $WorkspacePath -SpecContent $SpecContent `
                    -ColdStart $ColdStart -OpenCodeConfigPath $OpenCodeConfigPath -ModelRef $ModelRef
                return @{
                    Passed                        = $result.TestPassed -and $result.RepairApplied
                    Reason                        = "Test: $($result.TestPassed), Repair: $($result.RepairApplied)"
                    StructuredTrace               = $result.StructuredTrace
                    RepairApplied                 = $result.RepairApplied
                    UsedValidStructuredToolEvents = $result.UsedValidStructuredToolEvents
                }
            }
        }

    return $txnResult.RunOutput
}

# Stub for Get-OpenCodeStagedConfigContent (copy from Invoke-OpenCodeCapabilityContract.ps1).
function Get-OpenCodeStagedConfigContent {
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$EndpointUrl,
        [Parameter(Mandatory)][string]$SessionId
    )
    $script:AirlockOpenCodeProviderId = "airlock"
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
            apiKey  = "airlock-session-$SessionId"
        }
        models  = $models
    }
    return ($config | ConvertTo-Json -Depth 6)
}
