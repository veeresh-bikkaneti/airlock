# Quickstart Playbook

A beginner-friendly guide to running Airlock. No Ollama installed, no model pulled, no idea if your PC can handle it? That's the point — you don't need to know any of that up front.

## What this platform does for you

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

Ollama is installed automatically on first run if missing — you do **not** need to install it yourself. This step can take several minutes (download + install via winget) with little visible progress in our console — that's normal, let it finish.

## Running it

**Double-click `Start-AI.bat`** in the repo root. That's the whole interaction — no terminal to open, no command to type.

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
```

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
| `ai-start` | Same as `Start-AI.ps1` |
| `ai-stop` | Same as `Stop-AI.ps1` |
| `ai-port` | Shows the port, model, and whether it's healthy right now |
| `ai-provider` | Shows which provider (local or cloud fallback) is active |

## How model selection actually works

You never have to guess if a model fits your PC. The picker:
- Sizes against your **system RAM** (not VRAM) — Ollama offloads to CPU/RAM automatically if it doesn't fit on the GPU, so RAM is the real ceiling.
- Requires 20% headroom above the model's size before considering it a fit.
- Prefers the largest model that still fits comfortably.
- Only reaches out to Hugging Face if nothing in the curated list (`config/models.json`) fits — see [`06-Model-Acquisition-Backlog.md`](06-Model-Acquisition-Backlog.md) for the full backlog behind this.

## Reading the logs

Every run writes a JSON-lines audit log to `%USERPROFILE%\.ai-platform\logs\<date>.jsonl`, in addition to the colored console output. Each line has a timestamp, action, result (`STARTED`/`SUCCESS`/`WARNING`/`FAILED`), and a human-readable message — useful if something fails and you want the full story, not just the last line on screen.

## If something goes wrong

- **Ollama installation fails** — the script will print an error with a manual install link (https://ollama.com/download). This can happen on locked-down machines where `winget` isn't available or isn't allowed to install software. You can use `-NoAutoInstallOllama` to skip auto-install if you manage Ollama separately.
- **Script won't parse / weird syntax errors** — you're probably running it under Windows PowerShell 5.1 instead of PowerShell 7. Use `pwsh .\scripts\Start-AI.ps1`, not `powershell .\scripts\Start-AI.ps1`.
- **Port already in use** — run with `-Force` to kill the existing instance, or `-Port` to pick a different one.
- **Model pull/download stuck or failed** — check the audit log for the exact step it failed at; background pulls are session-scoped, so closing the terminal mid-download will kill the job (known limitation).

## Where to go next

- [`01-Local-AI-Platform-Blueprint.md`](01-Local-AI-Platform-Blueprint.md) — the architecture and design principles behind all this.
- [`05-Provider-Fallback-Matrix.md`](05-Provider-Fallback-Matrix.md) — what happens when local models aren't enough and cloud fallback kicks in.
- [`06-Model-Acquisition-Backlog.md`](06-Model-Acquisition-Backlog.md) — the backlog and status of the auto-discovery/pull/run feature this playbook describes.
