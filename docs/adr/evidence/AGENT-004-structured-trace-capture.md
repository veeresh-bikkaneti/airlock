# AGENT-004: Structured Tool-Event Trace Capture Evidence

## Implementation Status

### Request-ID Correlation — Code Implemented, Needs Live Verification

**Requirement:** Verify tool-call → tool-result → next turn sequence by matching request IDs.

**Code implementation:** Extracts ID from tool_call events, finds matching tool_result events, counts matched pairs. Only sets `usedStructuredToolEvents = true` when call+result pair found (lone calls don't count). Field names: checks `id`, `callID`, `call_id` in that order; exact field name pending evidence-collector confirmation on real --format json output.

**What needs verification:** 
1. Confirm exact ID field name in real tool_use/tool_call events from live run
2. Confirm field name for tool_result events  
3. Re-run against live capture, verify `$toolResultCount > 0` (call+result pairs detected)

**Timeline:** Field name confirmation from evidence-collector; code will work unchanged once confirmed (uses `??` operator for field fallback).

### Workspace Escape Detection — Logic Correct, Needs Real Trigger

**Requirement:** Detect out-of-workspace file access (e.g., `/src/...` or `C:\Windows\...`).

**Code implementation:** Parses filepath from tool events, normalizes both paths via `GetFullPath`, checks containment with `StartsWith`. Logic is sound; no unit test exercises it (trial instruction is well-scoped, model stays in-bounds).

**What needs verification:**
1. One real trial intentionally instructing model to access outside workspace (e.g., "also read/write `C:\Windows\temp\...`" or `/etc/passwd`-equivalent)
2. Capture output showing `OutOfWorkspace=$true` in trial result
3. If model won't escape on instruction alone, document whether this is a feature or constraint

**Timeline:** Evidence-collector runs escape-trigger trial, captures real `$outOfWorkspace=$true`.

### Pi-Worker Contract — Deferred (Disclosed Gap)

**Status:** Code-reviewed, unit-tested (18/18 pass), shares JSON parsing logic with OpenCode; zero live evidence.

**Why deferred:** Evidence-collector tested OpenCode CLI only. Pi requires Docker + hermes-container infrastructure not available in verification environment.

**Disclosed gap:** Pi contract is code-complete but live-verified only for OpenCode path. Matches AGENT-003's disclosed-gap pattern (Ollama-only verified, other runtimes intentionally deferred).

**How to close:** AGENT-007 acceptance testing runs live Pi trials.

## Test Status

- All 11 OpenCode contract unit tests pass
- Request-ID correlation logic added (pending live verification)
- Workspace escape detection logic added (pending real trigger trial)
- Pi deferred with explicit disclosure

## Required Evidence Before Merge

1. **Exact ID field names** — one JSON capture showing both tool_use/tool_call and tool_result events with their ID fields
2. **OutOfWorkspace=$true** — one real trial output where escape attempt is detected and guard fires
3. **Pi disclosure confirmation** — explicit note in ADR-012 table that Pi path is code-reviewed/tested but live-verified only for OpenCode

Once evidence-collector provides these three items, code is ready for reality-checker final verdict.
