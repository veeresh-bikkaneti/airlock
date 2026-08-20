# ADR-008: Environment injection safety — provenance, inheritance diagnosis, and complete uninstall

## Status
Proposed. An earlier draft of this ADR (2026-08-14, discarded) was written before the codebase was read and assumed airlock mutated global environment. **It does not.** Most of that draft's invariants are already implemented in `profile-helpers.ps1` and `Stop-AI.ps1`; this ADR keeps only the genuine gaps.

Related: ADR-006 (task router and handoff policy); `ai-claude-on` already calls `ai-handoff`.

## Context

### What already exists (verified in code, not assumed)

A four-day debugging incident on 2026-08-10..14 traced `API Error: Connection refused — a firewall or proxy may be blocking it (ConnectionRefused)` in Claude Code to a stale `ANTHROPIC_BASE_URL=http://127.0.0.1:8787` left behind by **Headroom**, a third-party context proxy. Airlock was not the cause.

Airlock already defends against this class of bug:

| Defence | Where | Status |
|---|---|---|
| Session-scoped injection only, never registry or settings.json | `ai-claude-on`, `profile-helpers.ps1:642-687` | Implemented |
| Liveness probe before injecting (`Test-NetConnection`, refuses if dead) | `profile-helpers.ps1:663-667` | Implemented |
| Stash/restore of pre-existing values rather than blind delete | `Resolve-ClaudeOnStash` / `Resolve-ClaudeOffRestore` | Implemented |
| Teardown clears the redirect | `Stop-AI.ps1:126-132` | Implemented |
| Dead-redirect scan across Process/User/Machine + `.claude/settings*.json` | `ai-doctor`, `profile-helpers.ps1:705-790` | Implemented |
| Backend guard (refuses when active backend isn't Ollama, since vLLM has no Messages API) | `profile-helpers.ps1:652-657` | Implemented |
| README warns that a settings.json `env` block has no off switch and survives `ai-stop` | `README.md:155` | Implemented |
| Regression test for the toggle | `scripts/Test-ClaudeToggle.ps1` | Implemented |

The design intent is correct and the README is accurate. What follows are the four things that were still missing when the incident happened, each of which would have shortened it.

### Gap 1 - `ai-doctor` diagnoses the value, not the carrier

This is the gap that cost four days. Final evidence from the incident:

```
HKCU\Environment  ANTHROPIC_BASE_URL =            <- clean
HKCU\Volatile Env ANTHROPIC_BASE_URL =            <- clean
Process/ANTHROPIC_BASE_URL = http://127.0.0.1:8787  <- dirty, in EVERY new shell
parent chain: pwsh(26596) -> Code(31612) -> Code(4028) -> explorer.exe(65300)
Get-NetTCPConnection -LocalPort 8787 -State Listen -> (empty)
```

`ai-doctor` would correctly flag the Process-scope dead redirect and print `Fix (this shell): Remove-Item Env:\ANTHROPIC_BASE_URL`. That fix works, and evaporates in the next terminal, because on Windows a process receives a **copy** of the environment block at creation and never re-reads the registry. `explorer.exe`, started at login while the registry was still poisoned, froze the bad block and hands it to every child: taskbar launches, VS Code, every integrated terminal. Cleaning the registry cannot reach an already-running ancestor. Only a sign-out or reboot clears it, which is exactly what finally worked.

`ai-doctor` says "restart every open shell and every running agent CLI" at the end, which is directionally right but doesn't name the carrier or tell the user a reboot is required. The disagreement between a clean registry and a dirty process is the *signature* of inheritance, and the tool has both numbers in hand already — it just doesn't draw the conclusion.

### Gap 2 - no provenance, so foreign injectors can't be named

`ai-claude-on` sets `AI_CLAUDE_ON_ACTIVE` and `AI_CLAUDE_PREV_*`, but those are stash bookkeeping, not provenance. `ai-doctor` therefore cannot distinguish "airlock set this" from "some other tool set this". The incident's culprit was foreign (Headroom). A `DEAD REDIRECT` line that also said *not set by airlock* would have redirected the investigation on day one.

### Gap 3 - no scan for third-party session hooks

The re-poisoning mechanism was a `SessionStart` hook (matcher `startup|resume`) in the global `~/.claude/settings.local.json`:

```json
"command": "C:/Users/veere/.local/bin/headroom.EXE wrap selfheal --marker headroom-wrap-selfheal"
```

It re-applied the variable after every manual fix, which is why three correct fixes each appeared to work and then regressed. `ai-doctor` reads those files already — it parses `.env.ANTHROPIC_BASE_URL` — but ignores the `hooks` block sitting beside it.

### Gap 4 - no uninstall

`grep -rl uninstall --include=*.ps1` returns nothing. `install.ps1` is a one-line `irm | iex` with no reverse. A user who wants out edits `$PROFILE` by hand and guesses at `~/.ai-platform`. Separately, any uninstall must warn that **running processes keep a frozen copy of the environment**, the same problem as Gap 1 in its uninstall form.

## Decision

Four additions. No change to the existing injection model, which is already correct.

**D1: `ai-doctor` gains inheritance diagnosis.** When a value is dirty at Process scope, clean at User *and* Machine scope, and its port is dead, classify it as `ORPHANED POINTER (inherited)` rather than a plain dead redirect. Walk `Win32_Process` parents from `$PID`, print the chain, and branch on the top of it:

- Chain reaches `explorer.exe` or another session root: remediation is **sign out or reboot**, stated with the reason: a registry fix cannot modify an already-running process's environment block.
- Chain tops out at a named restartable process: remediation is restart that process and its children.

**D2: provenance on every injection.** `ai-claude-on` additionally sets `AIRLOCK_INJECTED=1`, `AIRLOCK_ENDPOINT`, `AIRLOCK_INJECTED_AT` (ISO-8601), `AIRLOCK_VERSION`. `ai-doctor` reports any endpoint variable lacking `AIRLOCK_INJECTED=1` as **foreign**, naming that it was set by something other than airlock. `ai-claude-off` clears the provenance set alongside the stash set.

**D3: hook scan.** `ai-doctor` parses the `hooks` block of every `.claude/settings*.json` it already opens and flags any `SessionStart` (or `startup`/`resume`-matched) hook whose command mutates environment or wraps a CLI, printing the file, matcher, and verbatim command. It reports, it does not edit; the user decides.

**D4: `ai-uninstall`.** Removes `~/.ai-platform`, the `profile-helpers.ps1` line from `$PROFILE`, and firewall rules; leaves Ollama and pulled models alone (state so, don't surprise anyone). Then enumerates processes still carrying `ANTHROPIC_BASE_URL`/`OPENAI_*` pointed at the platform port and prints the sign-out/reboot notice. Supports `-WhatIf`.

**Non-decision, stated so it isn't re-litigated:** airlock keeps injecting into the *current shell* rather than spawning a wrapped child (`airlock run -- claude`). The child-spawn model is structurally safer, but `ai-claude-on` is a PowerShell function whose whole ergonomic value is that the shell you're already in becomes the Claude Code shell. The stash/restore plus `Stop-AI.ps1` teardown covers the same failure modes at a fraction of the disruption. Revisit only if stash/restore proves unreliable in practice.

**Hard constraint, unchanged:** the base URL must never be written to any `settings.json` `env` block by airlock. Anthropic's docs confirm a settings-file `env` value **overrides a shell export**, so any such write would silently defeat `ai-claude-on`/`ai-claude-off` entirely. The README already warns humans about this; CI should now enforce it (see BACKLOG AIR-H4).

## Consequences

**Positive**
- The single hardest failure in this class (clean config, dirty process) becomes a named diagnosis with a correct remediation, instead of three plausible fixes that each regress.
- Foreign injectors are identified as foreign, so airlock stops being the first suspect for problems it didn't cause.
- Self-healing hooks, which defeat all manual repair by design, become visible in one command.
- Uninstall stops being an undocumented manual procedure — a real adoption blocker for anyone evaluating an `irm | iex` installer.

**Negative**
- `ai-doctor` grows a `Win32_Process` walk, so it needs CIM access and gets slower by roughly the cost of ten CIM queries. Acceptable for a diagnostic that runs on demand.
- Provenance adds four variables to the injected set, which will show up in anything that dumps the environment. This is the intended trade: visible provenance is the point.
- The hook scan will flag legitimate third-party hooks. It must be worded as "found, review this" and never as "this is broken".
