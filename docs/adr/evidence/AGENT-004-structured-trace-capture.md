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

**Change:** Switched to `--format json` flag to emit structured JSON event stream (one JSON object per line).

```powershell
# Before
$proc = Start-Process -FilePath $opencodeCommand.Source `
    -ArgumentList @("run", "-m", "$($script:AirlockOpenCodeProviderId)/$ModelRef", "--auto", $instruction) `
    -WorkingDirectory $WorkspacePath -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $WorkspacePath ".stdout.log") `
    -RedirectStandardError (Join-Path $WorkspacePath ".stderr.log")

# After (real structured JSON event stream)
$proc = Start-Process -FilePath $opencodeCommand.Source `
    -ArgumentList @("run", "-m", "$($script:AirlockOpenCodeProviderId)/$ModelRef", "--auto", "--format", "json", $instruction) `
    -WorkingDirectory $WorkspacePath -NoNewWindow -PassThru `
    -RedirectStandardOutput (Join-Path $WorkspacePath ".stdout.log") `
    -RedirectStandardError (Join-Path $WorkspacePath ".stderr.log")
```

**Event Detection:**

```powershell
# Before (negative inference)
$usedStructuredToolEvents = -not (Test-AirlockOpenCodeRawToolEventInStdout -Stdout $stdout)

# After (positive observation of JSON events with type field)
$usedStructuredToolEvents = $false
$stderrLines = @($stderr -split "`n" | Where-Object { $_.Trim() })
foreach ($line in $stderrLines) {
    try {
        $json = $line | ConvertFrom-Json
        if ($json.type -match 'tool') { $usedStructuredToolEvents = $true; break }
    } catch { }
}
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

## Structured Event Format (Real Observations Needed)

OpenCode `--format json` emits one JSON object per line. Real observed structure to be captured from live sandboxed trial runs inside `Invoke-AirlockHarnessConfigTransaction` scope.

The code currently checks for `$json.type -match 'tool'` as a flexible positive indicator — exact event type field values (e.g., `"type": "tool-call"` vs. `"type": "call_tool"` vs. something else) will be confirmed during live verification.

Example placeholder (structure not yet verified live):
```json
{"type": "tool-call", "requestId": "...", "toolName": "write_file", "arguments": {...}}
{"type": "tool-result", "requestId": "...", "success": true, "result": {...}}
```

## Request-ID Correlation (To Be Verified)

Once real `--format json` events are captured from a live sandboxed trial, verify:
1. Model issues a structured event with `type` field containing "tool" and includes `requestId`
2. Harness executes and returns result with matching `requestId`  
3. Model sees result and proceeds

## Test Coverage

Both test suites verify:
- `Test-OpenCodeCapabilityContract.ps1`: All 11 checks pass
- `Test-PiCapabilityContract.ps1`: All 18 checks pass

Unit tests cover config correlation, parameter passing, and JSON parsing without requiring live OpenCode/Pi/Docker installs.

## Live Verification (Required Before Merge)

Real sandboxed trials inside `Invoke-AirlockHarnessConfigTransaction` scope needed:

1. **Success case:** Model correctly completes task (e.g., writes output.md)
   - Run `opencode run --auto --format json` inside Airlock sandbox
   - Capture full stdout (JSON event stream)
   - Extract actual `type` field values from tool-related events
   - Verify code regex `$json.type -match 'tool'` correctly matches them

2. **Failure case:** Model falls back to raw JSON, task fails
   - Capture full stdout to verify no tool-type events present
   - Confirm `$usedStructuredToolEvents` correctly is false

3. **Hang investigation** (known issue from team-lead testing)
   - Both `--format json --auto` runs hung and timed out (~120s)
   - Unclear root cause: `--auto`+json interaction? cold-start? config pollution?
   - Verify timeout correctly triggers trial failure: `ProcessSucceeded=$false`, `SanitizedInfo="timedOut=true"`
   - If hang is reproducible, document trigger conditions

Do not merge until live observations confirm: (a) exact event types captured, (b) parser correctly identifies them, (c) timeout behavior is correct.
