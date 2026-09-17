# Quickstart Playbook

A beginner-friendly guide to running Airlock. No Ollama installed, no model pulled, no idea if your PC can handle it? That's the point — you don't need to know any of that up front.

## Pick a door first

Airlock has **two doors**. They are not interchangeable, and the chat one will happily start a model that cannot use tools. First run is **any PC** — yours, not the author's ThinkPad.

| You want | Run this | Skip this |
|---|---|---|
| A coding agent with bash/read/write tools | `ai-agent-start` with **no `-Profile`**. It sizes Unsloth Dynamic 3.0 to *this* box's free VRAM, then a live Pi 3/3. Explicit `-Profile` still works if you mean a catalogue entry. | `Start-AI.bat` / `ai-start`. That's chat. Not GLM/Grok/cloud Qwen. |
| Chat, completions, "talk to a local model" | Double-click `Start-AI.bat` (or `ai-start`). Rest of this playbook. | Don't expect tool loops. Ollama 7b printing JSON is a known miss, not a setup bug. |

Coding door, one line (needs PowerShell 7, same as below):

```powershell
ai-agent-start -DownloadConfirmed
```

No `-Profile` is the point. Airlock reads **this** machine: free VRAM first, then free RAM. GPU-fit Unsloth is the fast door (16 GB class → `UD-Q3_K_XL`; smaller cards step down, **candidate-only**). If the GPU is too small but RAM can hold the GGUF, we mmap it on CPU — the same "run a heavy model on RAM" trick, labeled slow, still Pi. A live Pi pass on this box is the only coding certificate. `-WhatIf` to see the plan. `-ForceVerify` for a live contract, not a cached pass. `-Profile <id>` only if you really mean a specific catalogue entry (ADR-012: installed-but-unrequested is still never auto-selected). Then you're done with this playbook; the rest is the chat door.

## What the chat door does for you

You run one script. It figures out the rest:
1. Installs Ollama if missing (one-time via winget), then checks if it's running (starts it if not).
2. Reads how much RAM/VRAM your machine has.
3. Picks the best model that actually fits your hardware — from a curated list first, then Hugging Face if nothing curated fits.
4. Pulls/downloads that model in the background if it isn't already local.
5. Starts it and gives you a ready-to-use local endpoint.
6. Logs every step in plain English so you can see what happened.

## Prerequisites

Only one thing, one-time:
- **PowerShell 7** (`pwsh`), not the old Windows PowerShell 5.1. Check with:
  ```powershell
  $PSVersionTable.PSVersion
  ```
  Major version must be `7`. If not, install it from `winget install Microsoft.PowerShell`.

Chat door only: Ollama is installed automatically on first run if missing — you do **not** need to install it yourself. This step can take several minutes (download + install via winget) with little visible progress in our console — that's normal, let it finish. Coding door (`ai-agent-start`) does not use Ollama.

## Running the chat door

**Double-click `Start-AI.bat`** in the repo root. That's the whole chat interaction — no terminal to open, no command to type. Coding agents: you already skipped this; use `ai-agent-start`.

A console window opens and tells you in plain language what's happening: hardware detected, model chosen and why, download/pull progress, and when the model is ready. When it's done, press any key to close the window — the platform keeps running in the background.

First run on a machine with no models pulled yet will take longer (it's downloading). Every run after that is fast, because the model is already local.

If `Start-AI.bat` tells you PowerShell 7 isn't installed, run the one-line install it prints (`winget install --id Microsoft.PowerShell -e`), then double-click the file again.

### Backend selection (first run only, if you have an NVIDIA GPU)

If your machine has an NVIDIA GPU and Docker Desktop is running, the startup script will prompt you **once** on first run:

```
NVIDIA GPU + Docker detected. Choose your local backend:
  [O] Ollama - works everywhere, broad model support (default)
  [V] vLLM   - NVIDIA GPU required, faster for concurrent requests
Choice [O/v]
```

Type `V` for vLLM (higher throughput for batch requests) or just press Enter for Ollama (safe default, always works). Your choice is saved, so this prompt won't appear again on future runs.

### If you prefer the terminal

`Start-AI.bat` just wraps this — run it directly if you want more control over flags:
```powershell
.\scripts\Start-AI.ps1
```

## Common options

```powershell
.\scripts\Start-AI.ps1 -Model qwen2.5-coder:7b   # pin a specific model, skip auto-selection
.\scripts\Start-AI.ps1 -Port 5000                # use a specific port instead of auto-picking one
.\scripts\Start-AI.ps1 -Force                    # kill any existing instance and start clean
.\scripts\Start-AI.ps1 -SkipVault                # skip the secret-vault check (local-only session)
.\scripts\Start-AI.ps1 -NoAutoInstallOllama      # skip auto-install of Ollama (manage it yourself)
.\scripts\Start-AI.ps1 -Backend vllm             # force vLLM, even if a previous run fell back to Ollama
```

If vLLM ever fails to start (Docker not running, container crash, etc.), Airlock automatically remembers "use Ollama instead" for next time — so you're not stuck waiting through the same failed vLLM attempt on every single run. Use `-Backend vllm` above whenever you're ready to give it another try.

### Changing your backend choice after first run

Your backend choice (Ollama or vLLM) is persisted in `%USERPROFILE%\.ai-platform\config\provider-policy.json` under `preferredLocalProvider`. To switch:

```powershell
# Edit the file directly
notepad "$env:USERPROFILE\.ai-platform\config\provider-policy.json"
# Change "preferredLocalProvider": "ollama" to "vllm" or vice versa, then save

# Delete the choice to be prompted again (if you want to reconsider)
Remove-Item "$env:USERPROFILE\.ai-platform\config\provider-policy.json" -Force
# Next run of ai-start will prompt again if vLLM is viable
```

## Stopping it

**Double-click `Stop-AI.bat`**, or run `.\scripts\Stop-AI.ps1` yourself. Add `-CleanFirewall` if you want the firewall rule `ai-start` created removed too.

## Everyday shortcuts (optional)

If you add `scripts/profile-helpers.ps1` to your PowerShell profile (see Step 9 of [`02-Windows-Implementation-Guide.md`](02-Windows-Implementation-Guide.md)), you get short commands instead of full script paths:

| Command | What it does |
|---|---|
| `ai-start` | Chat door. Same as `Start-AI.ps1`. Not tool-calling. |
| `ai-agent-start` | Coding door (ADR-016). No `-Profile` sizes Unsloth to *this* box, then live Pi 3/3. Flags: `-Profile` (explicit catalogue id), `-WhatIf`, `-ForceVerify`, `-DownloadConfirmed`. |
| `ai-stop` | Same as `Stop-AI.ps1` |
| `ai-port` | Shows the port, model, whether it's healthy, and progress on any model still downloading |
| `ai-provider` | Shows which provider (local or cloud fallback) is active |
| `ai-claude-on` / `ai-claude-off` | Point Claude Code at your local model for this window only, then undo it — the safe way to try it without a setting that can outlive the platform |
| `ai-doctor` | One command that finds a leftover "point Claude Code / aider / Copilot at localhost" setting anywhere on your PC and tells you exactly how to remove it |

## How model selection actually works

You never have to guess if a model fits your PC. The picker:
- Sizes against your **graphics card's free memory (VRAM)** if you have one — not system RAM. A model that doesn't fit your GPU can technically still run by spilling onto the CPU, but that's minutes-per-response slow, not "slow but usable." No GPU detected? Then system RAM is the ceiling instead, same as before.
- Requires 20% headroom above the model's size before considering it a fit (a model needs more than just its file size once it's actually thinking).
- Prefers a model you already have downloaded over a same-size one you don't, so it never makes you wait for an extra download when something on disk already works.
- Among models that still fit, a known-failed agentic loop (`agenticLoopVerdict: fail` in `config/models.json`) loses to an unproven or passing one. Chat, not coding: this does not make the winner coding-ready.
- Among what's left, picks the largest model that still fits comfortably.
- Only reaches out to Hugging Face if nothing in the curated list (`config/models.json`) fits — see [`06-Model-Acquisition-Backlog.md`](06-Model-Acquisition-Backlog.md) for the full backlog behind this.

## Reading the logs

Every run writes a JSON-lines audit log to `%USERPROFILE%\.ai-platform\logs\<date>.jsonl`, in addition to the colored console output. Each line has a timestamp, action, result (`STARTED`/`SUCCESS`/`WARNING`/`FAILED`), and a human-readable message — useful if something fails and you want the full story, not just the last line on screen.

## If something goes wrong

- **Ollama installation fails** — the script will print an error with a manual install link (https://ollama.com/download). This can happen on locked-down machines where `winget` isn't available or isn't allowed to install software. You can use `-NoAutoInstallOllama` to skip auto-install if you manage Ollama separately.
- **Script won't parse / weird syntax errors** — you're probably running it under Windows PowerShell 5.1 instead of PowerShell 7. Use `pwsh .\scripts\Start-AI.ps1`, not `powershell .\scripts\Start-AI.ps1`.
- **Port already in use** — run with `-Force` to kill the existing instance, or `-Port` to pick a different one.
- **Model pull/download stuck or failed** — check the audit log for the exact step it failed at; background pulls run as detached processes, so closing the terminal no longer kills the job. If a pull recorded FAILED, the next `ai-start` automatically falls back to the smallest curated model instead of saying "pending" forever.
- **Claude Code (or aider, or Copilot) suddenly can't connect to anything — even the real cloud API, even for unrelated projects** — this is almost always a leftover "point this tool at localhost" setting from a previous local-model experiment, still active after the platform stopped. It shows up as a scary-sounding but wrong error like "a firewall or proxy may be blocking it." Run `ai-doctor` — it checks every place this kind of setting can hide and tells you the exact command to remove it. Then restart whichever terminal/app was affected.

## Coding door: from proof to a running agent

`ai-agent-start` proves tool-calling on *your* hardware and publishes a certificate — it does not, by itself, run your task. The landing flow is three commands:

```powershell
# 1. Prove the coding door on this hardware (sizes the model to your VRAM,
#    pulls it, runs the live tool-call contract, publishes the certificate).
#    Watch for LEDGER: warnings (this profile failed here before) and the
#    THROUGHPUT: line (measured tok/s on your hardware - "slow but real"
#    is honest, not a refusal).
ai-agent-start -Harness pi-worker

# 2. Author a job manifest from the live certificate (secure defaults:
#    network disabled, no merge/push, bounded time and tool steps).
.\scripts\New-AgentJobManifest.ps1 -Task "Fix the failing Test-Foo suite" -RepoPath "C:\source\project"

# 3. Launch the worker (isolated git worktree, locked-down container,
#    produces an unmerged patch - never merges or pushes by itself).
.\scripts\Start-AgentWorkerJob.ps1 -JobId <printed-id>
```

Notes:

- The certificate and its evidence pass TTL are short (~5 minutes for the evidence key): launch the worker promptly after `ai-agent-start`, or re-run it.
- Past contract failures are kept in `state\fail-ledger.jsonl` so the next run warns instead of rediscovering them. A ledger hit never refuses — it is memory, not a verdict.
- Prefer the OpenCode harness instead? `ai-agent-start -Harness opencode -PersistHarnessConfig` keeps the *proven* staged config live at `~/.opencode/opencode.json` after a passing trial (timestamped backup retained for rollback), then `cd` your repo and run `opencode`. Without `-PersistHarnessConfig` the trial config is restored away by design.

## Where to go next

- [`01-Local-AI-Platform-Blueprint.md`](01-Local-AI-Platform-Blueprint.md) — the architecture and design principles behind all this.
- [`05-Provider-Fallback-Matrix.md`](05-Provider-Fallback-Matrix.md) — what happens when local models aren't enough and cloud fallback kicks in.
- [`06-Model-Acquisition-Backlog.md`](06-Model-Acquisition-Backlog.md) — the backlog and status of the auto-discovery/pull/run feature this playbook describes.
