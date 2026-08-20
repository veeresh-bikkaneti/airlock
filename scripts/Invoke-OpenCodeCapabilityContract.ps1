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

# Builds the OpenCode global config content for one profile/endpoint. Pure
# string construction - kept separate from the transaction so its shape is
# directly assertable in a test without staging a real file.
function Get-OpenCodeStagedConfigContent {
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [Parameter(Mandatory)][string]$EndpointUrl,
        [Parameter(Mandatory)][string]$SessionId
    )
    $config = [ordered]@{
        model    = $ModelRef
        provider = [ordered]@{
            baseUrl = $EndpointUrl
            apiKey  = "ollama"
        }
        # Correlates a running opencode process back to the exact transaction
        # that staged its config (§8.1's "Verify config correlation").
        airlockSessionId = $SessionId
    }
    return ($config | ConvertTo-Json -Depth 5)
}

# One workspace trial's harness invocation: runs `opencode run` against the
# disposable workspace with the fixed §7.2 instruction, then classifies the
# raw observations. Requires a real OpenCode CLI + validated endpoint - see
# Test-OpenCodeCapabilityContract.ps1 for what is unit-tested (the config
# content and the config-transaction correlation via a mocked Run) versus
# what needs live hardware (§10.2).
function Invoke-OpenCodeWorkspaceTrial {
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$OpenCodeConfigPath
    )
    $instruction = "Read seed.md. Create output.md containing exactly the value after MARKER=. Do not access files outside this workspace. Reply exactly DONE."

    $proc = Start-Process -FilePath "opencode" `
        -ArgumentList @("run", "--config", $OpenCodeConfigPath, $instruction) `
        -WorkingDirectory $WorkspacePath -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput (Join-Path $WorkspacePath ".stdout.log") `
        -RedirectStandardError (Join-Path $WorkspacePath ".stderr.log")

    $stdout = Get-Content (Join-Path $WorkspacePath ".stdout.log") -Raw -ErrorAction SilentlyContinue
    $outOfWorkspace = [bool]($stdout -match '\.\.[\\/]' -or $stdout -match '[A-Za-z]:\\(?!.*airlock)')
    $usedStructuredToolEvents = [bool]($stdout -notmatch '(?m)^\s*\{"(action|tool_calls?)"')  # a raw JSON-looking tool object in plain stdout means the harness fell back to unstructured text, not a real tool event.
    $toolLoop = [bool]($stdout -match '(?i)(retry|repeating).{0,40}(retry|repeating)')

    return @{
        ProcessSucceeded              = ($proc.ExitCode -eq 0)
        OutOfWorkspaceRequestDetected = $outOfWorkspace
        UsedValidStructuredToolEvents = $usedStructuredToolEvents
        ToolResultLoopDetected        = $toolLoop
        SanitizedInfo                 = "exitCode=$($proc.ExitCode)"
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
                Invoke-OpenCodeWorkspaceTrial -WorkspacePath $WorkspacePath -Marker $Marker -OpenCodeConfigPath $OpenCodeConfigPath
            }
        }

    return $txnResult.RunOutput
}
