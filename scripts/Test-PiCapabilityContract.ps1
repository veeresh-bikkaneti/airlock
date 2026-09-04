# Self-check for Invoke-PiCapabilityContract.ps1 (ADR-012 Phase C, §7.3).
# Covers the pure docker-run argument construction (endpoint/model wiring,
# read-write workspace mount) - does NOT cover a real Pi container
# invocation, which requires a real Docker install + built hermes-agent
# image + a validated, reachable Ollama endpoint (§10.2; not available in
# this environment).
# Run: pwsh -File scripts/Test-PiCapabilityContract.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "Invoke-PiCapabilityContract.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing Invoke-PiCapabilityContract.ps1..." -ForegroundColor Cyan

# --- Get-PiContainerRunArgs: pure endpoint/model wiring ---

$args1 = Get-PiContainerRunArgs -ModelRef "qwen3-coder:30b" -EndpointUrl "http://127.0.0.1:12347/v1" -WorkspacePath "C:\temp\ws1" -Instruction "do the thing" -ImageName "hermes-container-hermes-agent"

Assert-True ($args1 -contains "-v") "run args mount a volume"
Assert-True ($args1 -contains "C:\temp\ws1:/workspace") "workspace is bind-mounted read-write at /workspace (no :ro, unlike the real-session repo mount)"
Assert-True ($args1 -contains "OLLAMA_HOST=host.docker.internal:12347") "OLLAMA_HOST port comes from the certificate's endpoint, not an independent port probe"
Assert-True ($args1 -contains "OPENAI_BASE_URL=http://host.docker.internal:12347/v1") "OPENAI_BASE_URL is built from the exact certificate endpoint port"
Assert-True ($args1 -contains "AIRLOCK_MODEL=qwen3-coder:30b") "AIRLOCK_MODEL is set from the certificate's model, not a container-side hardcoded default"
Assert-True ($args1 -contains "hermes-container-hermes-agent") "the built image name is passed through"
Assert-True ($args1 -contains "qwen3-coder:30b") "the model is also passed as an explicit --model arg (mismatch between env and arg would be detectable)"

$args2 = Get-PiContainerRunArgs -ModelRef "m2" -EndpointUrl "http://127.0.0.1:9999/v1" -WorkspacePath "C:\ws2" -Instruction "x"
Assert-True ($args2 -contains "OLLAMA_HOST=host.docker.internal:9999") "a different certificate endpoint port changes the derived OLLAMA_HOST, not a fixed/default port"
Assert-True ($args2 -contains "hermes-container-hermes-agent") "ImageName defaults to the compose-built image name when not overridden"

# --- ConvertTo-AirlockCmdLineArg: AGENT-PI-01 regression, a multi-word arg must survive as ONE argv entry ---

Assert-True ((ConvertTo-AirlockCmdLineArg "Read seed.md. Create output.md.") -eq '"Read seed.md. Create output.md."') "a multi-word instruction is quoted as a single command-line argument, not left to be word-split"
Assert-True ((ConvertTo-AirlockCmdLineArg "noSpaces") -eq "noSpaces") "an argument with no whitespace/quotes is left unquoted"
Assert-True ((ConvertTo-AirlockCmdLineArg 'has "quotes"') -eq '"has \"quotes\""') "embedded double quotes are backslash-escaped before the wrapping quotes"

# --- Resolve-AirlockPiTrialObservations: Linux-container path detection (not Windows drive letters) ---

$clean = Resolve-AirlockPiTrialObservations -ExitCode 0 -Stdout "Reading /workspace/seed.md`nWriting /workspace/output.md`nDONE"
Assert-True (-not $clean.OutOfWorkspaceRequestDetected) "paths under /workspace are not flagged as an escape"
Assert-True $clean.ProcessSucceeded "exit code 0 -> ProcessSucceeded true"

$escapePasswd = Resolve-AirlockPiTrialObservations -ExitCode 0 -Stdout "cat /etc/passwd"
Assert-True $escapePasswd.OutOfWorkspaceRequestDetected "an absolute POSIX path outside /workspace (/etc/passwd) is flagged - this is the exact case a copy-pasted Windows-path regex would miss"

$escapeHome = Resolve-AirlockPiTrialObservations -ExitCode 0 -Stdout "reading /home/hermes/.pi/agent/config.json"
Assert-True $escapeHome.OutOfWorkspaceRequestDetected "an absolute POSIX path under a different root (/home/...) is flagged"

$escapeRelative = Resolve-AirlockPiTrialObservations -ExitCode 0 -Stdout "reading ../etc/passwd"
Assert-True $escapeRelative.OutOfWorkspaceRequestDetected "relative parent traversal is still flagged"

$failedProc = Resolve-AirlockPiTrialObservations -ExitCode 1 -Stdout "DONE"
Assert-True (-not $failedProc.ProcessSucceeded) "non-zero exit code -> ProcessSucceeded false"

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures Invoke-PiCapabilityContract check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All Invoke-PiCapabilityContract checks passed" -ForegroundColor Green
exit 0
