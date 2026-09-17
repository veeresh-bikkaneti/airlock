# testbymuse.md — Airlock Agent File & Agent-Calling Tests

*Written by Muse. A self-contained instruction + test file: hand it to any
agent — human or AI — and it can operate and validate Airlock end-to-end on a
Windows machine. Assumes the cold-machine and landing-gap patch sets are
applied (branch `feat/cold-machine-and-landing-fixes`, stacked on `eb65be7`).*

---

## 1. Agent identity

- **Role:** Airlock validation agent.
- **Mission:** take a Windows machine from cold to a *proven, landed* local
  coding agent — then prove it again on demand.
- **Prime directive:** never claim a capability that was not measured on this
  hardware. A certificate is a measurement, not a badge.

## 2. Command surface

These are the only calls the agent may make, in this order. Nothing else is
part of the contract.

| # | Call | Purpose | When |
|---|------|---------|------|
| 1 | `irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 \| iex` | Bootstrap a cold machine (installs PS7 + git via winget, clones, deploys) | Once, on pristine Windows |
| 2 | `ai-start` | Start the chat platform (Ollama door) | Daily driver; after install |
| 3 | `ai-agent-start -Harness pi-worker` | Prove the coding door: size → acquire → tool-use trial → certificate | After `ai-start` is healthy |
| 4 | `ai-agent-start -Harness opencode -PersistHarnessConfig` | Prove + land the OpenCode door | Alternative to 3 |
| 5 | `.\scripts\New-AgentJobManifest.ps1 -Task "<task>" -RepoPath "<repo>"` | Author a bounded, secure-by-default job manifest | Only with a valid certificate |
| 6 | `.\scripts\Start-AgentWorkerJob.ps1 -JobId <id> [-WhatIf]` | Run the worker in an isolated worktree | Only from a manifest; `-WhatIf` first |
| 7 | `opencode` | Interactive coding against the local model | Only after step 4 lands |

## 3. Operating rules

1. **Inspect → acquire → prove → land.** Never skip prove. A model that never
   produced a real `tool_use` event is not a coding model.
2. **Respect the TTLs.** Certificate: 24 h. Capability evidence: ~5 min.
   Launch the worker promptly after proving, or re-prove.
3. **Worker jobs are cages, not pets.** Network off, no credentials, no
   merge, no push, bounded wall-clock and tool steps. Output is a patch you
   review — never an auto-merge.
4. **Failures are data.** Contract failures append to
   `state/fail-ledger.jsonl`. A `LEDGER:` warning informs the next run; it
   never refuses it.
5. **Slow is allowed; impossible is not.** `slow-but-real` throughput is a
   passing grade. Refuse only when even RAM-mmap cannot fit the model.

## 4. Decision ladder (model sizing)

- Read VRAM via `nvidia-smi`. Pick the largest Unsloth quant on the
  Qwen3-8-27B ladder that fits with context headroom.
- Fall back honestly: smaller quant → CPU offload → RAM-mmap →
  documented refusal. Each step-down is recorded, never silent.

## 5. Agent-calling tests

Each test names the agent's action, the exact call, the observable, and the
pass criterion. Run in order; stop at the first red.

### ACT-1 — Tool-use proof (the agent actually calls tools)
- **Call:** `ai-agent-start -Harness pi-worker`
- **Observe:** trial transcript contains structured `tool_use` events; run
  ends `SUCCESS`; `state/active-agent.json` exists with `measuredToksPerSec`.
- **Pass:** certificate published. **Fail:** any success claimed without a
  `tool_use` event in the transcript.

### ACT-2 — Manifest authoring (the agent scopes its own work)
- **Call:** `.\scripts\New-AgentJobManifest.ps1 -Task "Add a Pester test for X" -RepoPath "C:\source\scratch"`
- **Observe:** `state/jobs/<id>/manifest.json` is schema-valid; `network`
  is `false`, `credentials` is `none`, `autoMerge`/`autoPush` are `false`.
- **Pass:** secure defaults hold without the agent asking for them.

### ACT-3 — Dry run (the agent previews before acting)
- **Call:** `.\scripts\Start-AgentWorkerJob.ps1 -JobId <id> -WhatIf`
- **Observe:** plan printed (worktree path, bounds, command).
- **Pass:** zero side effects — no worktree directory created, no container
  started.

### ACT-4 — Freshness refusal (the agent respects stale proof)
- **Call:** wait >5 min after ACT-1 (or use an expired evidence entry), then
  `.\scripts\Start-AgentWorkerJob.ps1 -JobId <id>`
- **Observe:** refusal naming the stale verdict and telling the agent to
  re-run `ai-agent-start`.
- **Pass:** clean refusal with guidance. **Fail:** crash, or silent launch on
  stale proof.

### ACT-5 — Ledger warning (the agent learns from failure)
- **Call:** stop Docker Desktop, run `ai-agent-start -Harness pi-worker`
  (expect failure), restart Docker, run again.
- **Observe:** `state/fail-ledger.jsonl` gains one JSON line; second run
  prints a yellow `LEDGER:` warning, then re-proves normally.
- **Pass:** warning present, re-proof not blocked.

### ACT-6 — OpenCode landing (the agent persists a proven config)
- **Call:** `ai-agent-start -Harness opencode -PersistHarnessConfig`
- **Observe:** `OPENCODE LANDED`; live `~/.opencode/opencode.json` contains
  the `airlock` provider; timestamped backup under `state\config-backups`.
- **Pass:** `opencode` in a repo talks to the local model. Then restore the
  backup and confirm the provider is gone — landing must be reversible.

### ACT-7 — Worker output (the agent delivers, never merges)
- **Call:** `.\scripts\Start-AgentWorkerJob.ps1 -JobId <id>` on a scratch repo.
- **Observe:** `jobs/<id>/worktree` holds an unmerged patch; `result.json`
  and redacted `audit.jsonl` exist; the scratch repo's own git log shows no
  merge commit and no push.
- **Pass:** patch delivered, nothing merged, nothing pushed.

## 6. Reporting

Report back, per run: the `SIZED:` line, the `THROUGHPUT:` line
(`measuredToksPerSec` + tier), ACT-1…ACT-7 pass/fail, and the tail of
`fail-ledger.jsonl` if non-empty. Numbers first, narrative second.
