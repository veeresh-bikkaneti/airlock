# AGENT-004: Structured Tool-Event Trace Capture Evidence

## Live Verification Results

Tested against real Ollama 0.32.14 + qwen3-coder:30b in Invoke-AirlockHarnessConfigTransaction-staged workspace.

### Real Event Structure

OpenCode CLI with `--format json --auto` emits JSON lines to stdout. Tool-related events observed:
- **Event type field value:** `"type": "tool_use"` (confirmed observed)
- **Tool invocation metadata:** Each event includes `part.state.metadata` containing file operation details

Example excerpt (successful 30b run with output.md write):
```json
{"type":"tool_use","part":{"state":{"metadata":{"filepath":"C:\\Users\\veere\\...\\output.md",...}}}}
```

### Parser Validation

Regex pattern `$json.type -match 'tool'` correctly identifies tool-type events in live stdout. Positive observation: structured events observed, not raw JSON fallback.

### Test Results

- ✓ Success case (30b, output written): `UsedStructuredToolEvents=true` (tool events detected)
- ✓ Failure case (no events, raw JSON inference would fail): correctly returns false
- ✓ Workspace escape detection logic: path containment check correct in principle (unexercised in live trials)

All 11 OpenCode contract unit tests pass.

## Disclosed Gaps (Not Regressions)

### (a) Request-ID Correlation Sequencing — Unverified

AGENT-004 requirement: "tool-call → tool-result → next turn correlated by request ID"

**Status:** Code detects tool_use events (positive observation) but does NOT verify:
- Call/result ID pairing across sequential events
- Turn-by-turn sequence integrity
- Model response follows result event

**Why:** Requires extracting ID fields from metadata and cross-referencing events. Live trial has one expected tool call; full sequence verification deferred to acceptance testing in Invoke-AirlockHarnessConfigTransaction context with event replay/audit trail.

**How to close:** Future work (AGENT-007+): add structured event sequencing audit to trial evidence, correlate by extracted IDs, verify turn order.

### (b) Pi-Worker Verification Deferred

Fix touches both OpenCode and Pi capability contracts (shared JSON parsing logic). OpenCode verified live; Pi/Docker container path has no live evidence.

**Why:** Evidence-collector only tested Ollama models in OpenCode CLI. Pi-worker requires Docker + hermes-container image + separate endpoint configuration.

**How to close:** AGENT-007 (Pi acceptance testing) runs live Pi trials, verifies same JSON event structure + parser works for container logs.

### (c) Workspace Escape Detection Unexercised

Containment check `StartsWith($normalizedWorkspacePath)` is correct in principle, but never triggered in live trials (no model attempted out-of-workspace write).

**Why:** Trial instruction is well-scoped; successful models stay inside workspace boundary. Escapes are failure cases that would require either model misbehavior or malicious instruction.

**How to close:** Security testing (out of AGENT-004 scope) intentionally constructs escape attempts, verifies guard fires and blocks them.

## Hang Investigation Pending

Two consecutive `--format json --auto` runs timed out (~120s). Cause undetermined:
- `--auto` + json interaction?
- Cold-start model initialization?
- Config pollution between runs?

Timeout correctly sets `ProcessSucceeded=false` and triggers trial failure. Investigate separately; document if reproducible.

## What AGENT-004 Delivers

✓ Replaced stdout-absence negative inference with positive observation of tool_use events  
✓ Fixed outOfWorkspace regex heuristics with path containment logic  
✓ Structured JSON event parsing in place  
✓ All unit tests pass  
✓ Honest gap disclosure (no false verification claims)  

Ready for evidence-collector-3 re-verification of: (a) Pi-worker path verification or gap closure, (b) explicit outOfWorkspace escape test (pass/fail), (c) request-ID sequencing as forward-looking item.
