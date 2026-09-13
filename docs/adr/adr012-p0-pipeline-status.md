# ADR-012 P0 Pipeline Status

## AGENT-003: False-pass gate fix (codingReady isolation)

**Status:** MERGED (2026-08-22) — d4d024f on main

**PR:** https://github.com/veeresh-bikkaneti/airlock/pull/34 (branch: air-adr012-agent003)

**Requirement:** `codingReady = artifactFit AND transportFit AND harnessFit` must be the sole publish gate; persist fit dimensions; re-check live residency/VRAM before reusing a cached pass.

**Developer changes:**
- Moved fit state check outside cache/contract block so Ollama always re-verifies live residency/VRAM even when using cached contract pass
- When fitState.CodingReady is false, set contractPassed = false to prevent certificate publication
- Persist fit dimensions in published certificate
- Handles honest gap for llama-server/lmstudio where residency/VRAM measurement unavailable

**Unit tests:** Pass (Test-StartAgentSession.ps1, Test-OpenCodeCapabilityContract.ps1)

**Live verification results (evidence-collector @ 5d761c9):**

COND 1 (codingReady sole publish gate): **PASS** — :268 sets `$contractPassed = $false` when `-not $fitState.CodingReady`, blocking publication.

COND 2 (fit dimensions persisted): **PASS with caveat** — fitState persisted in certificate; caveat: non-Ollama runtimes have `fitState: null` (honest gap).

COND 3 (live re-check before cache reuse): **FAILS** — `$contractResult` stays null on cache-hit path (:219-221), so fit call at :260 passes `$(if ($contractResult) {...} else { $false })` → always `$false` on cache hit. Live proof: cached path gives `CodingReady False` (TransportFit False); fresh path identical conditions gives `CodingReady True` (TransportFit True). Every Ollama cache hit now hard-fails at :268 with misleading "transport (no valid structured tool events)" when transport actually passed and that pass is what got cached.

**Fix applied (commit 88cef5c):** Developer persisted `transportReturnedValidToolEvents` in registry entry and restored on cache hits. ArtifactFit (VRAM/residency) continues re-checking fresh every hit.

**Re-verification results (evidence-collector @ 88cef5c):**

COND 1 (codingReady sole publish gate): **PASS** — :272 sets `$contractPassed = $false` on `-not $fitState.CodingReady`. Unchanged by fix.

COND 2 (fit dimensions persisted): **PASS** — transportReturnedValidToolEvents field persists and restores correctly through Set/Get helpers. Prior caveat stands: non-Ollama runtimes persist `fitState: null`.

COND 3 (live re-check before cache reuse): **PASS** — :224 restores field from entry on cache hit, :265 passes restored value. Live proof: cache hit with field=$true → CodingReady=True (was False before fix). ArtifactFit still computed fresh from live VRAM on every hit.

**Note:** Absent-field legacy entries map to $false instead of cache miss; transient issue (self-heals in 5 min when TTL expires). End-to-end publication still unproven live due to unauthorized ~/.opencode/opencode.json write.

**Reality-checker verdict (@ 88cef5c): FAIL on COND 1**

COND 1 has TWO fail-open bypasses that publish without evaluating the gate (nested if guards with no else):
- **Bypass A:** Non-Ollama runtimes skip gate entirely (fitState = null), certificate publishes unchecked
- **Bypass B (NEW, undisclosed):** Get-AirlockFreeVramGiB (:59-69) returns $null on 3 reachable paths (no nvidia-smi, non-zero exit, or exception). When $null, gate is skipped and publish proceeds. This box returns 15.26 GiB, masking the gap. Fail-open on the exact dimension the remedy names.

**Fix:** Add `else { $contractPassed = $false }` to both guards — the gate must evaluate on all paths.

COND 2: **PASS in substance** — only transportReturnedValidToolEvents persists, but that is the only non-recomputable input, so CodingReady is fully reconstructible. Textual wording gap noted but functionally satisfies intent.

COND 3: **PASS mechanically** — but inherits both COND 1 bypasses. When VRAM reads null on cache hit, re-check silently doesn't happen.

End-to-end unproven: **CODE-COMPLETE-UNPROVEN** (accepted — unauthorized write to ~/.opencode/opencode.json).

**Fix applied (commit d0c0a05):** Developer added else branches to fail-close both guards:
- Bypass A: Non-Ollama runtimes now fail-close (contractPassed=false) with specific failure reason
- Bypass B: VRAM measurement unavailable now fails-close (contractPassed=false) with specific failure reason

Gate now enforces on all paths. Tests pass. Ready for evidence-collector re-verification.

**Re-verification results (evidence-collector @ d0c0a05):**

COND 1 (codingReady sole publish gate): **PASS** — All paths now fail-closed: :267 (codingReady false), :270-271 (VRAM unmeasurable), :274-275 (non-Ollama) all set `$contractPassed = false`.

COND 2 (fit dimensions persisted): **PASS** — Blocked sessions don't publish fitState, failure lives in `$failureReasons` only. Meaning changes: null no longer "not applicable", now means "blocked".

COND 3 (re-check before cache reuse): **PASS** — Cache hit with field restored → CodingReady=True.

**CRITICAL REGRESSION — Non-Ollama profiles now unreachable:**
- :274-275 unconditional else blocks **all** non-Ollama runtimes from publishing certificates
- `config/agent-profiles.json` ships `llamacpp-qwen38-ud-q3-k-xl` (llama-server runtime)
- PR #23 (llama.cpp adapter) + PR #28 (Start-AgentSession wiring) are now dead code at runtime
- LM Studio profile (if added) would be identically blocked
- Scope issue: remedy said "sole publish gate", not "block every non-Ollama runtime"

**Options to fix:**
1. Implement residency/VRAM measurement for llama-server and lmstudio adapters
2. Gate the else on a profile-level `requiresFitVerification` flag so non-Ollama adapters opt in when ready

**Scope-corrected fix (commit 46c4d6f):** Gate scoped to Ollama only (the only runtime with residency/VRAM measurements). Non-Ollama profiles use contract pass as gate per "honest gap" pattern—not blocked, just lack measurements.

**Result:**
- Ollama: full `codingReady = artifactFit AND transportFit AND harnessFit` gate enforced ✓
- llama-server/lmstudio: contract pass is gate (honest gap, no blocker) ✓
- Shipped `llamacpp-qwen38-ud-q3-k-xl` profile: can publish again ✓
- Future adapters: can ship without fit measurement, no dead code ✓
- Tests pass (all 10 Test-StartAgentSession checks)

**Unchanged caveats:** `?? $false` legacy-entry issue (transient, self-heals at TTL); end-to-end publication still CODE-COMPLETE-UNPROVEN.

**Final verification (evidence-collector @ 46c4d6f): All three conditions PASS**

COND 1 (sole publish gate for measurable path): PASS — Bypass B fail-closed correctly. Non-Ollama paths reachable (contract pass as gate).

COND 2 (fit dimensions persisted): PASS — Registry persists transportReturnedValidToolEvents (the only non-recomputable input), certificate carries fitState dimensions.

COND 3 (re-check before cache reuse): PASS — Bypass B fixed, ArtifactFit recomputes fresh per hit, no longer inherits bypass.

**Reality-checker verdict (@ 46c4d6f): PASS with one condition**

All three conditions met. Bypass B genuinely fixed. Fit dimensions properly recorded (registry vs. certificate distinction noted).

**CONDITION:** Non-Ollama runtimes (llama-server, lmstudio) remain gated on contract pass alone with fitState=null (unmeasured, honest gap). The remedy text says "sole publish gate" is literally false for two of three runtimes. Reality-checker recommends adding this to the retest-gaps table as its own gap row, not a disclosure footnote. Consumers must not read fitState=null as "verified"; null means unmeasured.

**Caveats unchanged:** Legacy `?? $false` is fail-closed (correct, don't touch). End-to-end publication CODE-COMPLETE-UNPROVEN (unauthorized ~/.opencode/opencode.json write accepted).

**Stash note:** Reality-checker left git stash@{0} intact after conflict on `docs/superpowers/specs/2026-08-19-agent-bootstrap-design.md` — tree recovered, work recoverable at stash@{0}.

---

**AGENT-003 complete.** Merged to main (d4d024f). Non-Ollama gap row documented in ADR-012 table as disclosed condition.

---

## AGENT-004: Structured tool-event trace (no stdout-heuristic inference)

**Status:** BLOCKED — Second bug found, awaiting corrected commit

**PR:** https://github.com/veeresh-bikkaneti/airlock/pull/35 (branch: air-adr012-agent004, commit 4e0f1ea)

**Requirement:** Capture a structured trace (request-ID-correlated tool-call → tool-result → next turn) from the endpoint/proxy/harness; no stdout-absence inference.

**Initial rejection (team-lead):**
- PR #35 checked for JSON schema (`"type":"tool-call"`) that doesn't exist in real `--print-logs` output
- Real format is key=value log lines, not JSON

**Corrected approach (commit 4e0f1ea):**
- Use real `--format json` flag (emits JSON objects one per line to stderr)
- Flexible JSON parsing: parse lines, extract `type` field, check if it contains 'tool'
- Applied same approach to both OpenCode and Pi (no hardcoded event type names)

**Unit tests:** Pass (11/11 Test-OpenCodeCapabilityContract.ps1, 18/18 Test-PiCapabilityContract.ps1)

**Second bug found & fixed (commit a2d8b69):**
- Code was parsing stderr for JSON events
- But `--format json` writes to stdout, not stderr
- Fix: Swap to parsing `$stdout` lines (both OpenCode and Pi)

**New issue flagged (team-lead observation):**
- `--format json --auto` hangs and times out (~120s) on consecutive runs
- Unknown root cause: `--auto` + `--format json` interaction? Flaky cold-start? Config pollution?
- Need to verify: Does timeout correctly set `ProcessSucceeded=$false` and `SanitizedInfo="timedOut=true"`, or does it leave stale state?

**Unit tests:** Pass (11/11 OpenCode, 18/18 Pi) — but tests don't catch hang behavior.

**Live verification still required before merge:**
1. Success case: sandboxed run to completion, capture stdout JSON stream, extract actual `type` field values
2. Failure case: confirm parser correctly identifies lack of tool events
3. Hang investigation: reproduce and document trigger conditions if reproducible, verify timeout state handling

**Team-lead clearance (commit a2d8b69):** Diff reviewed. Stream bug confirmed fixed (parses stdout, matches real output). Pi contract consistent (stdout+stderr, real JSON parse, `.type -match 'tool'`). Evidence file honest about unverified checklist items. Cleared for live verification with specific scope.

**Live verification scope (evidence-collector checklist):**
1. **SUCCESS case:** Real sandboxed opencode run where model completes task (writes expected file)
   - Capture real stdout JSON stream
   - Extract actual `type` field value(s) observed
   - Verify regex `-match 'tool'` catches them (not just artifact existence)
2. **FAILURE case:** Reproduce raw-JSON-fallback scenario (qwen2.5-coder:7b known to trigger)
   - Confirm `$usedStructuredToolEvents` correctly comes back `$false`
3. **Hang investigation:** `--format json --auto` consecutive runs hang (~120s)
   - Reproduce or rule out
   - Verify `ProcessSucceeded=$false` and timeout handling are correct (not silent pass)
4. **Document real event type value:** Replace placeholder language with actual value observed (e.g., "tool-call", "tool_use", etc.)

**Optional (CODE-COMPLETE-UNPROVEN if not feasible):** Pi/Docker live verification (requires running Pi worker container).

**Live verification results (evidence-collector @ a2d8b69):**

✅ **CHECKLIST 1 (SUCCESS case): PASS.** qwen3-coder:30b, 88s, exit 0, output.md written.
- Real `type` values observed: `step_start`, `text`, `tool_use`, `step_finish`
- Real tool event type: **`tool_use`**
- Regex proof: `'tool_use' -match 'tool'` → matched
- Sample event: `{"type":"tool_use",...,"part":{"type":"tool","tool":"write",...,"state":{"status":"completed"},...}}`

✅ **CHECKLIST 2 (FAILURE case): PASS.** qwen2.5-coder:7b, 36s, no output.md.
- Types: `step_start`, `text`, `step_finish` (no `tool_use`)
- Result: `usedStructuredToolEvents = False` ✓
- Better than old heuristic: raw JSON in text field correctly identified as failure (old approach would have incorrectly passed)

✅ **CHECKLIST 3 (Request-ID correlation): PASS.** Observable via `sessionID`/`callID`/`messageID`
- `tool_use` event embeds `callID`, `messageID`, `state.status` → tool-call → result → next turn sequence correlatable
- Tool result is embedded in same `tool_use` event's `state.output` (not separate event)

❌ **CHECKLIST 4 (Hang investigation): NOT REPRODUCED.** Three consecutive `--auto --format json` runs: 70s / 29s / 36s, all successful, no hang observed on this host.

---

**BLOCKER — `--format json` introduces regression in `outOfWorkspace` guard:**

Line 129: `$outOfWorkspace = [bool]($stdout -match '\.\.[\\/]' -or $stdout -match '[A-Za-z]:\\(?!.*airlock)')`

**Problem:** Under `--format json`, every tool event embeds absolute workspace path in metadata: `"filepath":"C:\\Users\\veere\\...\\output.md"`. The regex `(?!.*airlock)` assumes paths contain "airlock", but real workspaces use GUIDs: `~/.ai-platform/workspaces/<guid>` — no "airlock" string anywhere.

**Result:** Inverted logic on live run:
- Failed 7b run (no output written): `outOfWorkspace = False` (correct)
- Successful 30b run (output written): `outOfWorkspace = True` (WRONG — marked as escaping workspace)

**Impact:** Contract fails closed on success. Every successful run rejected as out-of-workspace.

**Fix:** Compare parsed JSON `part.state.metadata.filepath` against real workspace path from transaction context, not regex raw stdout.

**Evidence file note:** Real event type value is `tool_use`, not placeholder. Developer owns evidence doc; awaiting commit with fix.

---

**Next steps:** Developer fixes outOfWorkspace guard by comparing parsed JSON filepath against workspace context. Then re-run evidence-collector to verify regression is gone, then reality-checker verdict.
