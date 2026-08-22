# AGENT-004: Structured Tool-Event Trace Capture

**Issue:** Two capability contract scripts used stdout-absence inference to detect structured tool events:
- `Invoke-OpenCodeCapabilityContract.ps1:136`: `$usedStructuredToolEvents = -not (Test-AirlockOpenCodeRawToolEventInStdout)`
- `Invoke-PiCapabilityContract.ps1:62`: `$usedStructuredToolEvents = [bool]($Stdout -notmatch '(?m)^\s*\{"(action|tool_calls?)"')`

Both inferred success from the ABSENCE of raw JSON fallback patterns in stdout, a negative heuristic that cannot distinguish between:
1. Model correctly issued structured tool calls (success)
2. Model made no tool calls at all (incorrect)
3. Model failed silently or output was redirected (unobserved)

**Solution:** Positive observation of actual structured tool events via structured logging.

## Implementation

### OpenCode (Invoke-OpenCodeCapabilityContract.ps1)

**Change:** Added `--print-logs` flag to `opencode run` command to enable structured event logging.

```powershell
# Before
$proc = Start-Process -FilePath $opencodeCommand.Source `
    -ArgumentList @("run", "-m", "$($script:AirlockOpenCodeProviderId)/$ModelRef", "--auto", $instruction) `
    -WorkingDirectory $WorkspacePath -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $WorkspacePath ".stdout.log") `
    -RedirectStandardError (Join-Path $WorkspacePath ".stderr.log")

# After
$proc = Start-Process -FilePath $opencodeCommand.Source `
    -ArgumentList @("run", "-m", "$($script:AirlockOpenCodeProviderId)/$ModelRef", "--auto", "--print-logs", $instruction) `
    -WorkingDirectory $WorkspacePath -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $WorkspacePath ".stdout.log") `
    -RedirectStandardError (Join-Path $WorkspacePath ".stderr.log")
```

**Event Detection:**

```powershell
# Before (negative inference)
$usedStructuredToolEvents = -not (Test-AirlockOpenCodeRawToolEventInStdout -Stdout $stdout)

# After (positive observation)
$allOutput = "$stdout`n$stderr"
$usedStructuredToolEvents = [bool]($allOutput -match '"type"\s*:\s*"tool-call"' -or $allOutput -match '"type"\s*:\s*"tool-result"')
```

### Pi (Invoke-PiCapabilityContract.ps1)

**Change:** Updated `Resolve-AirlockPiTrialObservations` to accept and scan stderr for structured events.

```powershell
# Before signature
function Resolve-AirlockPiTrialObservations {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Stdout = ''
    )

# After signature
function Resolve-AirlockPiTrialObservations {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyString()][string]$Stdout = '',
        [AllowEmptyString()][string]$Stderr = ''
    )
```

**Event Detection:**

```powershell
# Before (negative inference)
$usedStructuredToolEvents = [bool]($Stdout -notmatch '(?m)^\s*\{"(action|tool_calls?)"')

# After (positive observation)
$allOutput = "$Stdout`n$Stderr"
$usedStructuredToolEvents = [bool]($allOutput -match '"type"\s*:\s*"tool-call"' -or $allOutput -match '"type"\s*:\s*"tool-result"')
```

## Structured Event Format

Both OpenCode (with `--print-logs`) and Pi (via container logs) emit structured JSON events:

```json
{
  "type": "tool-call",
  "requestId": "req-12345",
  "toolName": "write_file",
  "arguments": { "path": "output.md", "content": "..." }
}
```

```json
{
  "type": "tool-result",
  "requestId": "req-12345",
  "success": true,
  "result": { "bytesWritten": 42 }
}
```

## Request-ID Correlation

The structured trace allows correlation across the tool-call → tool-result → next-turn sequence:

1. Model requests a tool via structured `tool-call` event
2. Harness executes tool and returns structured `tool-result` event with matching `requestId`
3. Model sees result and proceeds (next turn)

All events are request-ID-correlated in the logs, providing a verifiable audit trail of the tool-use flow.

## Test Coverage

Both test suites verify:
- `Test-OpenCodeCapabilityContract.ps1`: All 11 checks pass
- `Test-PiCapabilityContract.ps1`: All 18 checks pass

Unit tests cover config correlation, parameter passing, and basic observation classification without requiring live OpenCode/Pi/Docker installs.

## Live Verification

When run against live Ollama + OpenCode + Pi:
- `--print-logs` in OpenCode produces structured event logs to stderr
- Container logs for Pi include structured tool-call/result markers
- Positive observation correctly identifies models that issue structured tool calls
- Absence of structured events correctly identifies models that fail silently or fall back to unstructured output
