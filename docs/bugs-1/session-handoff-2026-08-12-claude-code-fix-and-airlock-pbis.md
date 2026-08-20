# Session Handoff: Claude Code Connection Refused + Airlock PBIs — 2026-08-12

> **Supersedes** `session-handoff-2026-08-12-claude-code-connection-refused.md` written earlier in this session. That file named the wrong root cause (it blamed `GROK_CLI_CHAT_PROXY_BASE_URL` and `profile-helpers.ps1`, both of which were cleared and correct). Delete it.

**Status in one line:** Claude Code is fixed and connecting (root cause: `ANTHROPIC_BASE_URL` persisted at Windows User scope pointing at a dead proxy on port 8787); two PBIs written against the `airlock` repo; next action is recreating `.claude/settings.local.json`, which was overwritten during debugging and has no backup.

---

## Resume Point

- **In progress:** Restoring configuration state modified during outage debugging. `~/.claude/settings.json` already restored from `.bak`. Project-level files still need attention.
- **Next action:** Recreate `C:\Users\veere\source\repos\local-ai-platform\.claude\settings.local.json` from the reconstruction block in "Key Facts" below, then restart Claude Code and confirm both the connection and the plugin list.
- **State needed to continue:**
  - Work directory: `C:\Users\veere\source\repos\local-ai-platform`
  - Claude Code v2.1.228, Sonnet 5, Claude Pro
  - `claude.exe` at `C:\Users\veere\.local\bin\claude.exe`
  - Claude Code confirmed working — both `claude -p "say hi"` and the TUI
  - `~/.claude/settings.json` restored from `settings.json.bak` (all 34 ruflo plugins back to `true`)
  - `solution-audit@nsalvacao-claude-code-plugins` should stay `false` — it is the source of the SessionStart hook error

---

## Decisions Made

- **`ANTHROPIC_BASE_URL` removed at User scope and from `.claude/settings.local.json`** — it pointed at `http://127.0.0.1:8787`, which had no listener. Root cause of every "Connection refused" message. _(Decided — verified fixed)_
- **`solution-audit@nsalvacao-claude-code-plugins` disabled** — its `hooks.json` declares `"type": "prompt"` on `SessionStart`, which Claude Code rejects. Disabled in `enabledPlugins` rather than editing the plugin file, since a marketplace update would overwrite the edit. _(Decided)_
- **All 34 `ruflo-*@ruflo` plugins re-enabled** by restoring `~/.claude/settings.json` from `settings.json.bak`. _(Decided — reversal of an earlier decision made this session)_
- **Two PBIs filed against `airlock`** rather than patching locally, since the defects are in the published repo. _(Decided)_
- **Local model fallback needs architectural work before it can substitute for Claude Code** — four wiring defects plus one genuine capability ceiling. _(Proposed — PBI written, not yet triaged)_

---

## Key Facts & Specifics

### Root cause

```
ANTHROPIC_BASE_URL = http://127.0.0.1:8787
```

Persisted at Windows **User** scope (registry), *and* duplicated in the project's `.claude/settings.local.json` `env` block. Because it lived in the registry rather than a script, it survived every `settings.json` edit, every terminal restart, and every Claude Code restart.

Diagnostics:
- `Test-NetConnection 127.0.0.1 -Port 8787` → `TcpTestSucceeded : False`
- `Test-NetConnection api.anthropic.com -Port 443` → `TcpTestSucceeded : True`
- `[Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL','User')` → `http://127.0.0.1:8787`
- `[Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL','Machine')` → empty
- No PowerShell profile set it — all four `$PROFILE` paths came back clean
- Grep of `~/.ai-platform` and `~/.airlock-src` found no source for `8787`; provenance remains **unconfirmed**

Fix applied:
```powershell
[Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL', $null, 'User')
Remove-Item Env:\ANTHROPIC_BASE_URL
```

Four sibling variables were also at User scope on the same dead port. `ANTHROPIC_BASE_URL` and `COPILOT_PROVIDER_BASE_URL` cleared; these three remain:

```
OPENAI_API_BASE                = http://127.0.0.1:8787/v1
GROK_MODEL_GROK_BUILD_BASE_URL = http://127.0.0.1:8787/v1
GROK_CLI_CHAT_PROXY_BASE_URL   = http://127.0.0.1:8787/v1
```

### Files modified during debugging

| File | State | Backup |
|---|---|---|
| `~/.claude/settings.json` | Restored | `settings.json.bak` (pre-change), `settings.json.full` (post-ruflo-regex) |
| `.claude/settings.json` (project) | Minimal, 3 keys | `.claude/settings.json.backup`, `.claude/settings.json.broken` |
| `.claude/settings.local.json` | `{}` — **needs recreation** | `.bak` holds headroom-hook version only; not in git |
| `.claude/agents/` | **Deleted, 25 dirs** | Not in git (gitignored); regenerate via `npx ruflo@latest init` |

### Reconstruction block for `.claude/settings.local.json`

```powershell
@'
{
  "permissions": {
    "allow": [
      "Bash(python -m pip --version)",
      "Bash(python -c \"import platform; print\\(platform.machine\\(\\)\\)\")",
      "Bash(python -m pip install \"crewai[tools]\")",
      "Bash(py -0p)",
      "Bash(.venv-crewai/Scripts/python.exe -m pip install \"crewai[tools]\")"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "C:/Users/veere/.local/bin/headroom.EXE wrap selfheal --marker headroom-wrap-selfheal",
            "timeout": 10
          }
        ]
      }
    ]
  },
  "enabledMcpjsonServers": ["claude-flow", "ruv-swarm", "flow-nexus"]
}
'@ | Set-Content .\.claude\settings.local.json -Encoding utf8NoBOM
```

The `env` block containing `ANTHROPIC_BASE_URL` is deliberately omitted.

### Airlock local-fallback defects (one `ai-start` → `ai-code` session)

- Selected `qwen3-coder:30b` (18 GB) because it "fits 87.7 GB available" — sized against **system RAM**, while GPU showed **15 GB free / 16 GB**. Model spills to CPU; response time collapses.
- `ai-code` in `profile-helpers.ps1` **declares no parameters** — `ai-code -Model qwen2.5-coder:7b` silently discards the flag.
- `ai-code` calls bare `aider --model $modelArg` with **no `--openai-api-base`**, producing `litellm.AuthenticationError: Incorrect API key provided: ollama`. The README claims the opposite.
- vLLM burned 120 s then emitted one line: `ERROR: vLLM did not become healthy within 120s.` No container logs, no failure class.

Working aider invocation until fixed:
```powershell
aider --model openai/qwen2.5-coder:7b --openai-api-base http://127.0.0.1:12345/v1 --openai-api-key ollama
```

### Verified intact (not affected by debugging)

- `~/.claude/agents` — **278 files**, agency-agents untouched (only the *project-level* `.claude/agents/` was deleted)
- **SkillOpt** — a PyPI package (`pip install skillopt`), never in `enabledPlugins`, unaffected. Note its `claude_chat` backend launches `claude -p`, so it would have failed identically while the base URL was broken.
- **gstack** — never appeared in the 50-entry `enabledPlugins` list at any point; not disabled by anything done this session
- **ruflo npm CLI works** — `npx ruflo@latest swarm` returned help output normally

### Artifacts produced

- `PBI-airlock-anthropic-base-url.md` — the `ANTHROPIC_BASE_URL` defect
- `PBI-airlock-local-fallback-architecture.md` — 5-item epic on the local fallback path

---

## Open Questions & Next Steps

- [ ] **Recreate `.claude/settings.local.json`** — use the block above. _(owner: user)_
- [ ] **Regenerate `.claude/agents/`** — `npx ruflo@latest init`; inspect what it writes first. _(owner: user)_
- [ ] **Restart Claude Code and verify** — connection holds, plugins load, no SessionStart hook error. _(owner: user; depends on: the two items above)_
- [ ] **Decide on the three remaining 8787 variables** — clear only if no local gateway on 8787 is wanted. They break Copilot/Grok/OpenAI clients the same way, but not Claude Code. _(owner: user)_
- [ ] **Identify what wrote `8787` to User scope** — unresolved; grep found nothing in airlock. Confirm before scoping the PBI fix. _(owner: user)_
- [ ] **File both PBIs as GitHub issues** on `veeresh-bikkaneti/airlock`. _(owner: user)_
- [ ] **Confirm `.gitignore` covers `.claude/agents/`** — if intentional, regeneration is the only recovery path. _(owner: user)_

---

## Context & Rejected Paths

- **Why diagnosis took so long:** Claude Code's error text — "a firewall or proxy may be blocking it" — points at the wrong subsystem. Roughly two hours went into firewall rules, proxy checks, `netsh winhttp`, JSON validity, plugin hooks, and agent-description limits before the variable surfaced.
- **Rejected: missing hook files.** All helper files were present in `.claude/helpers/` and recently dated.
- **Rejected: firewall / corporate proxy.** `api.anthropic.com:443` responded throughout; `netsh winhttp show proxy` showed direct access.
- **Rejected: `headroom.EXE wrap selfheal` SessionStart hook.** Blanking `settings.local.json` did not fix it.
- **Rejected: `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`.** Removed as a suspect; refusal persisted afterward.
- **Correction made this session:** "ruflo is dead" was asserted after `Test-Path ...\marketplaces\ruflo\dist\src\index.js` returned `False`. That applies only to the **marketplace plugin checkout** (source-only clone, no build step). The **npm package works**. The 34 plugins were re-enabled on that basis.
- **Stale processes matter.** A running Claude Code TUI holds the environment it was launched with. `claude -p` succeeded while the TUI still failed, purely because the TUI predated the fix. Relaunch every process, not just the shell.
- **On the local model "hallucinating":** three causes conflated — wrong model at wrong speed (fixable), broken aider wiring (fixable), and a genuine 7B ceiling on multi-step tool calling across an 858-file repo (not fixable by platform work). The PBI separates these rather than promising a fix for the third.

---

## Parked for Later

- **Trim `enabledPlugins`** — 50 plugins push agent descriptions to ~16.5k tokens against a 15k limit. Selective disabling beats regex sweeps.
- **`.claude/settings.json` (project) currently minimal** — restore from `.backup` if the old permissions/hooks are wanted back.
