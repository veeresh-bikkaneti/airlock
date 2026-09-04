# Pi / Unsloth agentic path — design

Date: 2026-09-04
Status: Ready for implementation on `feature/adr-015-pi-unsloth-agentic-path`
ADR: `docs/adr/ADR-013-llama-cpp-pi-agentic-path.md`
Program: AIR-014 (docs honesty, parallel, different files) → **AIR-015 (this spec)** → AIR-016 coding-ready entry points → AIR-017 harness debt

## 1. Problem

The only live-passing agentic combination in this repository (Unsloth Qwen3.8-27B UD-Q3_K_XL + `llama-server` + Pi harness, 3/3 real tool events) lives on `origin/feature/adr-013-pi-harness-verification` and is not on `main`. `main` still has that profile with `candidateOnly: true` and the Pi contract wiring bugs that made the first live run hang.

## 2. Goal

After this branch merges, `main` contains:

- `config/agent-profiles.json` profile `llamacpp-qwen38-ud-q3-k-xl` with `candidateOnly: false` and the verified `runtimeArgs` (including `--reasoning-effort low` and `--flash-attn on`)
- Pi harness wiring that quotes multi-word instructions (AGENT-PI-01) and does not drop container CMD args
- The live-verification evidence docs
- ADR-013 as the decision record

A coding agent reading `agent-profiles.json` can see one non-candidate profile. CI still runs `scripts/Test-PiCapabilityContract.ps1`.

## 3. Non-goals

- Editing `CLAUDE.md` / `AGENTS.md` / `README.md` / `opencode.json.template` (AIR-014 owns those; this branch must `git diff` empty against them vs `main`)
- Cherry-picking the three CLAUDE.md-only commits from the pi-harness branch (`abcfdbc`, `cbb09a3`, `c45aaac`, `3e812f7`)
- Adding `xlam-proxy/` or flipping any xLAM profile out of `candidateOnly`
- Implementing `ai-agent-start` (AIR-016)
- Re-running GPU trials in this Linux sandbox (no GPU / no Windows pwsh required for the merge; unit tests only)
- Filing the opencode 282K issue (AIR-017)

## 4. Design

### 4.1 Source of files

Take file contents from `origin/feature/adr-013-pi-harness-verification` (commit `3e812f7` or its equivalent HEAD) for exactly these paths:

```
config/agent-profiles.json
hermes-container/Dockerfile
hermes-container/entrypoint.sh
scripts/Invoke-PiCapabilityContract.ps1
scripts/Test-PiCapabilityContract.ps1
docs/adr/evidence/ADR-013-unsloth-pi-live-verification.md
docs/adr/evidence/ADR-013-unsloth-fallback-GATES.md
```

Do **not** `git cherry-pick` the pi-harness commits: one of them is CLAUDE.md-only and one carries a `Co-Authored-By: Claude` trailer this repo forbids. Checkout those seven paths, review the diff, commit as this branch's own work.

### 4.2 Profile invariants

After checkout, `config/agent-profiles.json` must satisfy:

- `profiles` contains `profileId == llamacpp-qwen38-ud-q3-k-xl`
- that object's `candidateOnly` is JSON `false` (not string `"false"`)
- `runtime` is `llama-server`
- `runtimeArgs` contains `--jinja`, `--flash-attn`, `on`, `--n-gpu-layers`, `all`, `--reasoning-effort`, `low`

`ollama-gemma4-12b` stays `candidateOnly: true`.

### 4.3 Pi wiring invariants

`scripts/Invoke-PiCapabilityContract.ps1` must define `ConvertTo-AirlockCmdLineArg` and apply it before `Start-Process -ArgumentList`. `scripts/Test-PiCapabilityContract.ps1` must contain an assertion that a multi-word instruction stays one argv element.

`hermes-container/entrypoint.sh` must not drop CMD args (must exec `pi` with the remaining arguments). Dockerfile must normalize the entrypoint to LF if the pi-harness commit did.

### 4.4 ADR-013

The file `docs/adr/ADR-013-llama-cpp-pi-agentic-path.md` is already on this branch as the decision. Do not rewrite its Decision section. You may add a one-line "Implemented in" SHA after the landing commit if you amend; prefer a follow-up sentence in the evidence GATES file over rewriting history.

### 4.5 Tests

1. JSON/profile invariants: a small Python check in the implementer report (do not add a second Python test runner to the repo). CI will run the `.ps1`.
2. If `pwsh` exists: `pwsh -File scripts/Test-PiCapabilityContract.ps1` must exit 0.
3. If `pwsh` does not exist: record that in the report as the same disclosed gap this Linux sandbox already has; do not skip the Python profile/quoting-function presence checks.

## 5. Fail-closed

- If `git checkout origin/feature/adr-013-pi-harness-verification -- <path>` would also stage `CLAUDE.md`, abort and take paths one by one.
- If `candidateOnly` is still `true` after checkout, fail the task — do not hand-edit it to false without the evidence files present.
- If Test-PiCapabilityContract.ps1 loses the ConvertTo-AirlockCmdLineArg tests, fail.

## 6. Out of scope reminders

Do not "helpfully" update CLAUDE.md to say the passing path is now on this branch. AIR-014's contract currently says it is not on that branch; reconciling the two files is an integration step after both PRs exist, not this task.
