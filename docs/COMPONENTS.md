# Component Overview

This document explains **what each file/folder in the repository does** and **why it exists**.  It is written for beginners – no prior knowledge of PowerShell or Ollama is required.

---

## 📂 Top‑Level Directories

| Directory | Purpose |
|-----------|---------|
| `scripts/` | PowerShell helper scripts (`Start‑AI.ps1`, `Stop‑AI.ps1`, `profile‑helpers.ps1`, etc.). All user‑facing commands (`ai‑*`) live here. |
| `config/` | JSON configuration files that drive the platform – model registry, routing policies, secret templates, and tool templates. |
| `docs/` | Human‑readable documentation (`README.md`, `PLAYBOOK.md`, architecture diagrams, this COMPONENTS guide, etc.). |
| `hermes-container/` | Dockerised **Hermes** agent – a sandboxed AI assistant for job‑application tasks. It runs in isolation from your personal files. |
| `LICENSE` | MIT license – open source permissive license. |
| `README.md` | High‑level overview, quick‑start guide, architecture diagram, and usage examples. |
| `PLAYBOOK.md` | Step‑by‑step operational playbook (starting, switching models, cloud fallback, security checks, etc.). |
| `requirements.txt` / `main.py` | Minimal Python demo script used for quick sanity‑check of the OpenAI‑compatible endpoint. |

---

## 🔧 `scripts/`

| Script | What it does | Why you need it |
|--------|--------------|----------------|
| **`Start‑AI.ps1`** | • Scans for existing Ollama processes.<br>• Kills any rogue instances (single‑instance enforcement).<br>• Starts Ollama on **port 12345** bound to `127.0.0.1` only.<br>• Creates a Windows Firewall rule that **blocks inbound traffic** to that port (prevents accidental exposure).<br>• Performs RAM/VRAM health checks before loading a model.<br>• Verifies model digest and size.<br>• Writes structured audit logs (`logs/YYYY‑MM‑DD.jsonl`).<br>• Exposes environment variables (`OLLAMA_HOST`, `OPENAI_BASE_URL`). | Guarantees a clean, secure, and reproducible AI environment. Prevents the “multiple Ollama instances” problem that wastes GPU memory and breaks tools. |
| **`Start‑VLLM.ps1`** | • Detects hardware capability and Docker availability.<br>• Launches vLLM (OpenAI-compatible server) in a Docker container on port 12345.<br>• Health-checks the `/health` endpoint until it's ready.<br>• Writes state files (`active-provider.json`) for coordination with `Stop-AI.ps1`. | Optional higher-throughput backend for NVIDIA GPU owners. Called by `Start-AI.ps1` when the user chooses vLLM via backend selection prompt. |
| **`Get‑BackendCapability.ps1`** | • Checks if NVIDIA GPU drivers are installed.<br>• Checks if Docker Desktop is running.<br>• Returns a capability flag (true/false) for vLLM readiness. | Lets `Start-AI.ps1` only prompt for vLLM as a backend option when it's actually viable; prevents false choices. |
| **`Stop‑AI.ps1`** | • Finds and kills *both* the Ollama tray app and the server process, OR stops vLLM Docker container.<br>• Optionally removes the firewall rule (`-CleanFirewall`).<br>• Clears environment variables and session‑state files (`.active‑port.json`, `active‑provider.json`).<br>• Writes a final audit‑log entry. | Clean shutdown – no stray processes, no open ports, and a tidy state for the next start (works for both Ollama and vLLM). |
| **`Start‑MemoryService.ps1`** | • Launches the memory-service FastAPI application.<br>• Starts Chroma vector DB + LangGraph session checkpointing.<br>• Integrates with active backend's embeddings (Ollama `/api/embeddings` endpoint).<br>• Health-checks the API and firewall rule.<br>• Writes state file for coordination with `ai-memory-status`. | Enables vector DB + RAG + session memory for local AI. Marked as "Ollama-only" — degrades to no-op under vLLM (no embeddings endpoint). |
| **`Stop‑MemoryService.ps1`** | • Stops the FastAPI memory-service process.<br>• Cleans up state files. | Clean shutdown of memory-service without orphaned processes. |
| **`profile‑helpers.ps1`** | • Provides the **`ai‑*` command suite** that users source from their PowerShell profile.<br>• Wraps the underlying scripts to set environment variables automatically.<br>• Implements convenience helpers: `ai‑port`, `ai‑provider`, `ai‑switch`, `ai‑code`, `ai‑hermes‑start/stop`, `ai‑memory‑start/stop/status/on/off`, `ai‑audit‑last`, `ai‑policy`, `ai‑models`, `ai‑auth`, `ai‑cache`, `ai‑config`, `ai‑health`.<br>• Blocks direct `ollama serve` (users must use `ai‑start`). | Gives a **single, beginner‑friendly CLI**. Prevents users from accidentally bypassing the security/shutdown logic in `Start‑AI.ps1`. |
| **`Invoke‑CommitReview.ps1`** | • Reads `config/policies/commit‑policy.json` (list of regex/glob patterns).
• Examines the Git **staged** file list (`git diff --cached`).
• Categorises files as **BLOCKED**, **NEEDS‑APPROVAL**, or **AUTO‑APPROVED**.
• Unstages blocked files automatically, prompts the user for approval on the “needs‑approval” set, then runs `git commit` with a message.
| Prevents accidental committing of secrets, passwords, or other sensitive data. Enforces organization‑wide commit policy for AI‑assisted repos. |
| **`ai‑auth‑set`** (inside `profile‑helpers.ps1`) | Stores cloud provider API keys in a JSON file under `~/.ai-platform/config/auth.json`. The script **never** writes keys to version‑controlled files. |

---

## 📄 `config/`

| File | Explain the fields (beginner‑friendly) |
|------|----------------------------------------|
| **`models.json`** | - `localModels` – map of model name → metadata (size, parameters, context window, role, tags).<br>  *Purpose*: lets the platform know which models are installed, their capabilities, and which are “preferred” vs “fallback”.<br>- `fallbackOrder` – ordered list of model names the platform will try if the preferred model is unavailable.<br>- `defaultEndpoint` – the local Ollama HTTP endpoint (`http://127.0.0.1:12345/v1`).
| **`policies/provider‑policy.json`** | - `cloudFallbackEnabled` – `true` allows automatic switch to a cloud provider when a local model fails or is too small.
- `allowSensitiveDataToCloud` – if `false`, the platform will **never** send data to the cloud, even if fallback is enabled.
- `preferredLocalModel` – name of the model the platform should use by default.
- `localFallbackModels` – list of alternative local models to try if the preferred one is missing.
- `cloudProviderPriority` – ordered list of cloud services the platform will try (OpenRouter, OpenAI, Anthropic, etc.).
- `defaultCloudModels` – map of cloud provider → model name the platform will request when falling back.
| **`policies/commit‑policy.json`** | - `alwaysBlockPatterns` – glob patterns that **must never** be committed (e.g., `*\.env`, `*\.key`).
- `requireApprovalPatterns` – patterns that trigger a **user prompt** before committing (e.g., `*.md` containing sensitive sections). |
| **`auth.json.template`** | Template for cloud API keys. **Never** commit real keys – run `ai-auth-set <provider> <key>` to fill it in. |
| **`opencode.json.template`** | Configuration for the `opencode.ai` agent – points it at the local Ollama endpoint. |
| **`hermes-config.json.template`** | Config for the Hermes container's agent (cloud-model settings). |
| **`jcode-config.toml.template`** | Configuration for the `jcode` agent. |
| **`pi-models.json.template`** | Model registry mirror for the Pi.dev agent. |

---

## 🤖 Hermes Agent (`hermes‑container/`)

- **Purpose**: Provide a **sandboxed AI assistant** for job‑search and career‑related tasks without exposing any of your personal files.
- Runs in a Docker container with **all capabilities dropped** and **read‑only bind‑mount** of the `career‑ops` repository.
- Uses **cloud models** (OpenAI, Anthropic, etc.) for higher‑quality language generation while keeping your codebase completely private.
- Entry points: `run‑hermes.ps1` to start, `stop‑hermes.ps1` to stop and extract output.

---

## 🛡️ Security Checklist (what the platform enforces)

1. **Single‑instance Ollama** – never more than one server + UI app.
2. **Local‑only binding** – only `127.0.0.1`, never `0.0.0.0`.
3. **Inbound firewall block** – Windows rule `AI‑Platform‑Ollama‑Block‑<port>`.
4. **Audit logging** – every action (start, stop, model switch, commit review) is written to `logs/YYYY‑MM‑DD.jsonl`.
5. **Secret handling** – API keys stored in a local JSON file (`~/.ai-platform/config/auth.json`), never committed to source.
6. **Commit gate** – `Invoke‑CommitReview.ps1` blocks secrets from Git commits.
7. **Resource checks** – RAM >20 % free, VRAM >4 GB free before loading large models.
8. **Model digest verification** – ensures the exact binary you think you are using.

---

## 🚀 Getting Started (quick recap)

```powershell
# 1️⃣ One-line installer
irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex

# (Or manually: git clone + .\setup.ps1 if you prefer to review first)

# 2️⃣ Restart PowerShell to load profile
. $PROFILE

# 3️⃣ Start the platform (auto-pulls a model based on hardware)
ai-start

# 4️⃣ Verify everything is healthy
ai-health

# 5️⃣ Use AI coding assistant
ai-code   # launches `aider` with the correct endpoint

# 6️⃣ When done, cleanly shut down
ai-stop   # (or `ai-stop -CleanFirewall` to also delete the firewall rule)
```

---

## 📚 Where to Find More Info

- **Architecture diagram** – top of `README.md` (Mermaid graph).
- **Detailed playbook** – `PLAYBOOK.md` (step‑by‑step operational guide).
- **Security audit runbook** – `docs/04‑Security‑Audit‑Runbook.md`.
- **Provider fallback matrix** – `docs/05‑Provider‑Fallback‑Matrix.md`.
- **PowerShell module spec** – `docs/03‑PowerShell‑Module‑Spec.md` (full function signatures).

---

*All scripts contain inline comments for each logical block. If you need deeper explanations, consult the corresponding markdown files in `docs/`. Happy, secure AI coding!*