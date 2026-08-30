# AGENT-005: Repair-Loop Capability Contract — Evidence

Written by the human lead after 3 real live trials against `qwen3-coder:30b`
via real Ollama 0.32.14 + OpenCode 1.18.18 on this machine.

## Detection logic — proven correct

`Resolve-AirlockRepairLoopVerdict` (pure function, `scripts/Invoke-RepairLoopCapabilityContract.ps1`)
is unit-tested (`Test-RepairLoopCapabilityContract.ps1`, 4/4 pass, calling the
real function against real-shaped fixture data) and additionally verified
live against 3 real trials below.

## Fixture — proven correct

`test-fixture-demo/`: `Add-Numbers.ps1` has a real bug (`$a - $b` instead of
`$a + $b`); `Test-AddNumbers.ps1` genuinely fails with real `FAIL:` output
and exit code 1 before a fix, and would genuinely pass with real `PASS:`
output and exit 0 after one (confirmed by running the fixture's own test
directly, independent of any model).

## Live trials — 3/3 real, 3/3 failed (honest negative result)

Instruction used (matches the real harness's actual instruction, not a
hint-laden prompt): `"Read spec.md. Follow the task exactly."`

| Trial | Outcome | RepairLoopSucceeded (harness verdict) | Correct? |
|---|---|---|---|
| 1 | Model called `webfetch` on an unrelated random GitHub URL, then `explore` (invalid tool), then `glob`. Never read spec.md, never ran bash. | `False` | Yes — no repair happened |
| 2 | Model read spec.md, Add-Numbers.ps1, Test-AddNumbers.ps1 correctly, built a todo list, then hallucinated an unrelated `/home/user/...` path and got confused before ever running the test. | `False` | Yes — no repair happened |
| 3 | Model called `webfetch` on `"spec.md"` (wrong tool for a local file) and then `https://example.com` (unrelated). Never read the real files, never ran bash. | `False` | Yes — no repair happened |

The harness correctly reported `False` in all three cases — no bash tool
call was ever detected in any trial, matching what actually happened. This
is real, honest evidence that the DETECTION logic works correctly on
genuine negative cases; it does not include this repo's own AGENT-004
mistake of trusting narration.

## What's proven vs. not

- **Proven live:** the harness accurately classifies a real trial where the
  model does not complete the repair loop (3/3 real attempts, 3/3 correctly
  classified `False`).
- **Proven by unit test, not yet by a live positive trial:** the harness
  correctly classifies a trial where the model DOES complete the loop
  (fail-then-pass bash output) — verified against real-shaped synthetic
  data, not yet against an actual successful live run, because `qwen3-coder:30b`
  did not complete this specific compound task in 3 real attempts in this
  environment. This is itself informative: it suggests genuine difficulty
  for a local model to reliably complete a read-spec -> diagnose -> run-test
  -> repair -> rerun loop unaided in a single pass, which is closer to the
  honest answer this whole ADR-012 investigation exists to surface than a
  cherry-picked success would have been.

**Status: CODE-COMPLETE-UNPROVEN for the success path** (matching this
branch's own established convention for honestly-disclosed gaps, e.g.
AGENT-003's end-to-end publication). The contract itself — fixture,
detection logic, trial orchestration (3 cold + 3 warm) — is real, tested,
and live-verified on the failure path. Whether any locally-available model
can reliably complete the full loop is a separate, real open question, not
a code defect.
