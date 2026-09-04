# Gates: Unsloth Qwen3.8 fallback live verification (Pi harness)

OWNS: config/agent-profiles.json, scripts/Invoke-PiCapabilityContract.ps1,
scripts/Test-PiCapabilityContract.ps1, docs/adr/evidence/ADR-013-unsloth-*.md

Scope: prove (not claim) that `llamacpp-qwen38-ud-q3-k-xl` clears the live ADR-012 Pi
capability contract (`Invoke-AirlockPiCapabilityContract`, 3 trials) with real tool
calls against a real `llama-server` instance and a real Pi container, or prove it
doesn't and stop. Supersedes the earlier opencode-harness attempt on
`feature/adr-013-unsloth-verification` (commit `9768edf`, not merged into this
branch), which could not complete because opencode's real installed-skill system
prompt on this machine measured ~282K tokens — an opencode-specific environmental
blocker unrelated to this model, which is why ADR-013 moved to the Pi harness for
this candidate.

- [x] G1: Profile promoted out of candidate-only status, machine-checkable
  CHECK: node -e "const p=require('./config/agent-profiles.json');const pr=p.profiles.find(x=>x.profileId==='llamacpp-qwen38-ud-q3-k-xl');process.exit(pr&&pr.candidateOnly===false?0:1);console.log('PROMOTED')"
  EXPECT: PROMOTED
  EVIDENCE: MET. `candidateOnly` flipped to `false` in `config/agent-profiles.json`.
  See ADR-013-unsloth-pi-live-verification.md for the 3/3 real pass this is based on.

- [x] G2: Live-verification evidence doc shows real 3/3 contract pass, not just the transport/proxy layer passing
  EVIDENCE: MET, with the transport/capability distinction actively checked, not assumed.
  ADR-013-unsloth-pi-live-verification.md's "Not gaming the pass" section independently
  re-derives the verdict from raw artifacts rather than trusting the harness's own boolean:
  byte-exact `output.md` == `seed.md` marker comparison per trial (re-done here, not just
  cited from `Resolve-AirlockWorkspaceTrialVerdict`'s internal check); the raw stdout
  event-type histogram showing exactly 2 real `toolcall_*`/`tool_execution_*` events per
  trial (one `read`, one `write`) with their actual arguments
  (`{\"path\":\"seed.md\"}` / `{\"path\":\"output.md\",\"content\":\"<marker>\"}`), not a regex hit
  on the word \"tool\" inside prose; exactly 2 distinct `toolCallId`s per trial (rules out a
  tool-result retry loop presenting as a pass); clean `DONE` → `turn_end` → `agent_end` →
  `agent_settled` termination with `exitCode=0` on all three. All three trials show the
  identical clean pattern, independently confirmed for each rather than assuming trial 1
  generalizes.
  <!-- Manual by design: xLAM's near-miss was exactly this shape - proxy/transport layer
  passed 3/3 while the actual capability contract failed 3/3, and only byte-level
  evidence caught it. A regex for \"3/3\" or \"Passed: true\" in the doc would false-positive
  on that same case, so this gate requires reading the raw stdout/output.md artifacts
  the doc quotes, not just the harness's aggregate boolean, before G1's flipped flag is
  trusted. -->

- [x] G3: If FAIL instead of PASS, evidence doc names the specific failure mechanism (not \"didn't work\") and states whether prompt-level mitigation was attempted
  EVIDENCE: N/A as a fail-path gate (the real outcome is PASS, not FAIL) - documented
  instead for the real bug this pass required fixing along the way, same discipline as if
  it had been a fail: AGENT-PI-01 in ADR-013-unsloth-pi-live-verification.md names the
  exact mechanism (`Start-Process -ArgumentList` word-splitting the multi-word §7.2
  instruction into separate docker/pi argv entries, each treated as its own conversation
  turn by pi's `[messages...]` positional syntax), shows the isolated repro
  (`printf` inside the built image, no Pi/model involved), the fix
  (`ConvertTo-AirlockCmdLineArg`, a per-argument Win32-style quoter, applied before
  `Start-Process`), and the isolated re-verification of the fix before the real 3-trial
  run was attempted again. A prior fix attempt (`ProcessStartInfo` + async
  `OutputDataReceived`/`ErrorDataReceived` event handlers) is disclosed as tried and
  reverted - it crashed with `PSInvalidOperationException: There is no Runspace
  available to run scripts in this thread` because those .NET events fire on a
  thread-pool thread with no PowerShell runspace, so the simpler file-redirected
  `Start-Process` approach (already deadlock-safe, matches this file's pre-existing
  convention) was kept instead. A regression test for the fix was added to
  `Test-PiCapabilityContract.ps1` (18/18 passing).
