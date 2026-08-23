# AGENT-004: Structured Tool-Event Trace Capture Evidence

Rewritten by the human lead after three consecutive rounds of evidence that
did not correspond to real events (stale trial numbers reformatted into a
new table, a verification claim citing a commit never pushed to this
branch, an escape-trial claim built on an unrelated log file timestamped
before the code it supposedly tested existed). The evidence below is
grounded in live commands actually run, with output pasted verbatim.

## Real event schema (confirmed live, 2026-08-22/23)

`opencode run -m ollama/<model> --auto --format json <instruction>` emits
one JSON object per line to **stdout**. There is no separate
tool-call/tool-result event pair to correlate by ID — a single `tool_use`
event is atomic, carrying both the call and its outcome:

```json
{"type":"tool_use","timestamp":1787444468487,"sessionID":"ses_fd40255e5ffeyKauqDhOXweHnQ","part":{"type":"tool","tool":"write","callID":"call_nvj83uy2","state":{"status":"completed","input":{"content":"HELLO","filePath":"output.txt"},"output":"Wrote file successfully.","metadata":{"filepath":"C:\\Users\\veere\\AppData\\Local\\Temp\\claude\\agent004-probe3\\output.txt","exists":false}}}}
```

Captured live against `qwen3-coder:30b` via real Ollama 0.32.14 +
OpenCode 1.18.18 on this machine, task: "Write a file named output.txt
containing the word HELLO". `part.state.status` is the inline result —
there is nothing to pair against a second event, so the original
"request-ID correlation" framing (assuming a separate call/result event
pair) did not match the real product. `part.callID` is retained in the
schema for identification/logging but is not used for cross-event
matching, since there is no second event.

**Negative case, confirmed live against `qwen2.5-coder:7b`** (its known
weak tool-calling behavior — falls back to plain text with an embedded
fake tool JSON instead of a real tool call):

```json
{"type":"text","part":{"type":"text","text":"{\"name\": \"write\", \"arguments\": {\"content\": \"Hello, How can I help you today?\", \"filePath\": \"/path/to/output.txt\"}}"}}
```

`type` is `"text"`, not `"tool_use"` — correctly excluded by the
implementation below.

**Real, spontaneous out-of-workspace escape, same live 30b run as above**:
after writing the correct `output.txt`, the model went on to hallucinate
three unrelated `tool_use` writes to fake paths with no connection to the
task:

```json
{"type":"tool_use","part":{"type":"tool","tool":"write","callID":"call_n85ky0j8","state":{"status":"completed","input":{"filePath":"/home/user/project/docs/test_coverage_component_a.md"},"output":"Wrote file successfully.","metadata":{"filepath":"/home/user/project/docs/test_coverage_component_a.md","exists":false}}}}
```

This was not an adversarial prompt — the model did it unprompted after
finishing the real task. `[System.IO.Path]::GetFullPath('/home/user/project/docs/test_coverage_component_a.md')`
on Windows resolves to `C:\home\user\project\docs\test_coverage_component_a.md`,
which does not start with the real workspace root
(`C:\Users\veere\AppData\Local\Temp\claude\agent004-probe3`) — confirmed
directly in PowerShell.

## Implementation (`scripts/Invoke-OpenCodeCapabilityContract.ps1`)

```powershell
foreach ($line in $stdoutLines) {
    try {
        $json = $line | ConvertFrom-Json
        if ($json.type -eq 'tool_use' -and $json.part.type -eq 'tool' -and $json.part.state.status -eq 'completed') {
            $usedStructuredToolEvents = $true
            if ($json.part.state.metadata.filepath) {
                $filepath = $json.part.state.metadata.filepath
                $normalizedFilepath = [System.IO.Path]::GetFullPath($filepath)
                if (-not $normalizedFilepath.StartsWith($normalizedWorkspacePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $outOfWorkspace = $true
                    break
                }
            }
        }
    } catch { }
}
```

## Verification against real captured data

Ran this exact logic (via an isolated PowerShell snippet, not a mock)
against the three real transcripts above:

| Input | UsedValidStructuredToolEvents | OutOfWorkspaceRequestDetected |
|---|---|---|
| legit `tool_use`/`write`/`completed` event, in-workspace path | `True` (expected `True`) | `False` (expected `False`) |
| `tool_use` write to `/home/user/project/docs/...` | `True` | `True` (expected `True` — this is the real escape) |
| `text`-type fallback with embedded fake JSON | `False` (expected `False`) | n/a |

All three match expectations. Also ran `scripts/Test-OpenCodeCapabilityContract.ps1`
directly against this commit: all 10 checks pass.

## Pi-worker contract — disclosed gap (unchanged, not part of this fix)

`Invoke-PiCapabilityContract.ps1` received the equivalent structural fix in
an earlier commit on this branch but has zero live verification — Pi
requires a running Docker/Hermes container not available in this
environment. Code-reviewed and unit-tested (18/18 pass) only. This is an
explicit, disclosed gap (see the ADR-012 table), matching AGENT-003's
Ollama-only disclosure convention — not silent.

## `--auto --format json` intermittent hang

Retested 8 total live invocations across this investigation: 2 hung at
the timeout and were killed cleanly by the existing
`WaitForExit`/`Stop-Process` path (reported `ProcessSucceeded=$false`,
`SanitizedInfo="timedOut=true..."` as designed); 6 completed normally,
including a repeat of the exact task that hung earlier. Genuinely
intermittent, not deterministic — no root cause identified, but the
existing timeout-and-kill handling already fails safely. Not a blocker.
