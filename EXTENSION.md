# Airlock — VS Code Extension

Thin wrapper over this repo's own `ai-*` PowerShell helpers (`scripts/`).
Doesn't reimplement start/stop/health/model logic — just calls it.

## Commands
- **AI Platform: Start** — runs `ai-start`
- **AI Platform: Stop** — runs `ai-stop`
- **AI Platform: Health Check** — runs `ai-health`
- **AI Platform: Select Model** — quick-pick from `models.json`, then `ai-start -Model <name>` (restarts Ollama)
- **AI Platform: Switch Model (no restart)** — quick-pick from `models.json`, then `ai-switch <name>` (swaps the model on the running instance)
- **AI Platform: Launch Aider (ai-code)** — runs `ai-code`

A status bar item polls `http://127.0.0.1:<port>/api/tags` every
`healthPollSeconds` (default 15s) and shows running/stopped, reading the
active port and model from `~/.ai-platform/.active-port.json` when available
(falls back to `aiPlatform.healthPort`).

## Settings
- `aiPlatform.deployedScriptsPath` — where `profile-helpers.ps1` lives (default `~/.ai-platform/scripts`)
- `aiPlatform.modelsConfigPath` — override for `models.json` (default: sibling `config/` of deployedScriptsPath)
- `aiPlatform.healthPort` — canonical Ollama port (default 12345)
- `aiPlatform.healthPollSeconds` — 0 disables polling

## Dev
```
npm install
npm run compile
```
Then F5 in VS Code (Extension Development Host) to try it.

## Requires
Run `.\setup.ps1` from the repo root once to deploy `scripts/` and `config/`
to `~/.ai-platform` and wire `profile-helpers.ps1` into your PowerShell
profile. This extension is a client of the deployed copy, not a copy of it —
re-run `setup.ps1` after pulling script changes to redeploy them.
