# Windows Implementation Guide

## Goal
Set up a local-first AI environment on Windows 11 using PowerShell 7, Ollama (or vLLM for NVIDIA GPUs), aider, structured logging, and optional cloud provider fallback.

## Prerequisites
Install these first:
- Ollama Desktop.
- Python 3.11 or newer.
- Git.
- VS Code.
- PowerShell 7.

## Verification
Run these commands in `pwsh`, not Windows PowerShell 5:
```powershell
ollama --version
python --version
git --version
code --version
$PSVersionTable.PSVersion
```
Expected result: major PowerShell version is `7`.

## Step 1: Create folders
```powershell
New-Item -Path "$HOME\.ai-platform\scripts"  -ItemType Directory -Force | Out-Null
New-Item -Path "$HOME\.ai-platform\logs"     -ItemType Directory -Force | Out-Null
New-Item -Path "$HOME\.ai-platform\state"    -ItemType Directory -Force | Out-Null
New-Item -Path "$HOME\.ai-platform\policies" -ItemType Directory -Force | Out-Null
New-Item -Path "$HOME\.ai-platform\.env"     -ItemType File -Force | Out-Null
icacls "$HOME\.ai-platform\.env" /inheritance:r /grant:r "${env:USERNAME}:(R,W)"
```

### Why this matters
- `logs` stores runtime and audit records.
- `state` stores active provider and port metadata.
- `policies` stores declarative routing and security settings.
- `.env` exists only for non-secret local settings; do not store real API keys in it.

## Step 2: Pull local models
```powershell
ollama pull devstral-small-2:24b
ollama pull qwen2.5-coder:7b
ollama list
```
Use the larger model as preferred local coding model and the smaller model as a fallback if memory is limited.

## Step 3: Install aider
```powershell
python -m pip install aider-install
uv tool install aider-chat
aider --version
```
Record the installed version in your setup notes.

## Step 4: Store provider keys
Store only providers you plan to use — this writes to `~/.ai-platform/config/auth.json` (gitignored, never committed):
```powershell
ai-auth-set openrouter ""
ai-auth-set openai ""
ai-auth-set anthropic ""
ai-auth-set google ""
ai-auth-set azure-openai ""
ai-auth   # verify what's configured
```

`ai-start` separately checks for a registered PowerShell SecretManagement vault named `AIVault` and logs whether it's present. That check is informational only — nothing in the platform currently reads keys from a SecretManagement vault, so installing/registering one is not required.
Do not place these values in profile files, repository files, or command history exports.

## Optional: vLLM Backend for NVIDIA GPUs

**If you have an NVIDIA GPU** and want higher throughput for concurrent requests, `Start-AI.ps1` can use **vLLM** (via Docker) instead of Ollama. This is entirely optional:

- **Ollama** (default): Works on any Windows machine (CPU or GPU), broad model compatibility.
- **vLLM** (opt-in): Requires NVIDIA GPU + Docker Desktop + WSL2 backend. Faster for batch/concurrent inference.

On first run, if your machine has an NVIDIA GPU and Docker Desktop is running, you'll be prompted to choose. Your choice is persisted to `provider-policy.json` — you won't be asked again unless you delete that file.

### Prerequisites for vLLM path:
- NVIDIA GPU with CUDA support (check: `nvidia-smi`)
- Docker Desktop running with WSL2 backend
- NVIDIA Container Toolkit configured

If vLLM fails to start (e.g., GPU passthrough issue), the platform automatically falls back to Ollama.

Both backends expose the same endpoint: `http://127.0.0.1:12345/v1`. No client changes needed.

## Step 5: Create provider policy
Create `%USERPROFILE%\.ai-platform\policies\provider-policy.json`:
```json
{
  "cloudFallbackEnabled": false,
  "allowSensitiveDataToCloud": false,
  "preferredLocalProvider": "ollama",
  "preferredLocalModel": "devstral-small-2:24b",
  "localFallbackModels": ["qwen2.5-coder:7b"],
  "cloudProviderPriority": ["openrouter", "openai", "anthropic", "google", "azure-openai"],
  "defaultCloudModels": {
    "openrouter": "openai/gpt-4.1-mini",
    "openai": "gpt-4.1-mini",
    "anthropic": "claude-3-5-sonnet-latest",
    "google": "gemini-2.5-pro",
    "azure-openai": "gpt-4.1-mini"
  }
}
```

**Note:** `preferredLocalProvider` defaults to `"ollama"`. On first run with an NVIDIA GPU + Docker, `Start-AI.ps1` will prompt you to choose between `"ollama"` (always works) and `"vllm"` (faster for concurrent requests). Your choice is auto-saved here.

## Step 6: Create aider config
Create `%USERPROFILE%\.aider.conf.yml`:
```yaml
model: openai/devstral-small-2:24b
openai-api-base: http://127.0.0.1:12345/v1
openai-api-key: ollama
map-tokens: 1024
auto-commits: false
dark-mode: true
no-show-model-warnings: true
gitignore: true
edit-format: diff
cache-prompts: true
detect-urls: false
```

### Why these defaults are safer
- `auto-commits: false` keeps commit authority with the user.
- `edit-format: diff` makes review easier.
- `detect-urls: false` reduces unwanted network access.
- Loopback `openai-api-base` keeps the default provider local.

## Step 7: Add startup and stop scripts
Implement the scripts from the module specification artifact so the platform can:
- Discover or start Ollama.
- Write structured logs.
- Select the active provider by policy.
- Export only session-scoped environment variables.
- Shut down local services cleanly.

## Step 8: Add profile helpers
Update your PowerShell profile to expose commands such as:
- `ai-start`
- `ai-stop`
- `ai-port`
- `ai-code`
- `ai-provider`
- `ai-audit-last`

## Step 9: Validate end to end
```powershell
ai-start
ai-provider
ai-port
cd C:\your\project
ai-code
ai-stop
```
Check that:
- the selected provider is local by default,
- the endpoint is loopback-only,
- log files are written,
- no cloud key is used unless policy enables fallback.

## Daily workflow
1. Open `pwsh`.
2. Run `ai-start`.
3. Move to the project folder.
4. Run `ai-code`.
5. Review diffs before accepting changes.
6. Run `ai-stop` when finished.
