# Airlock

**A hardened, single-instance AI infrastructure for Windows with Ollama, PowerShell, and optional cloud fallback.**

One door open at a time — exactly one local model backend running, walled off from the outside, everything logged.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7+-green.svg)](https://github.com/PowerShell/PowerShell)
[![Ollama](https://img.shields.io/badge/Ollama-0.30+-orange.svg)](https://ollama.ai)
[![Version](https://img.shields.io/badge/version-0.2.0-blueviolet.svg)](CHANGELOG.md)
[![CI](https://github.com/veeresh-bikkaneti/airlock/actions/workflows/ci.yml/badge.svg)](https://github.com/veeresh-bikkaneti/airlock/actions/workflows/ci.yml)

See [`CHANGELOG.md`](CHANGELOG.md) for what's new in each release.

---

## 🎥 Demo

![Airlock demo](brag-output/brag-demo.webp)

15s clip from the full demo. GitHub doesn't play video inline in README files, so the full `brag.mp4` isn't tracked in git — see `brag-output/composition/` to re-render it.

---

## 🎯 The Problem We Solve

### Before This Platform

| Issue | Impact |
|-------|--------|
| **Multiple Ollama instances** running on different ports (11434, 12345, etc.) | Tools fail, models load multiple times into VRAM, confusion |
| **No single source of truth** for which port/model is active | Manual environment variable juggling, session state lost |
| **External exposure risk** — Ollama binds to `0.0.0.0` by default | Unintended network access to your local LLM |
| **No audit trail** for AI-assisted development | Cannot trace which model generated which code |
| **Cloud fallback is opaque** — no policy enforcement | Accidental data leakage to external providers |
| **Resource conflicts** — models fail to load due to memory pressure | Wasted time debugging "out of VRAM" errors |

### After This Platform

✅ **Single-instance enforcement** — only one Ollama process, always on port 12345  
✅ **Automatic firewall guard** — inbound traffic blocked by default  
✅ **Structured audit logging** — every API call logged with model/provider metadata  
✅ **Resource monitoring** — RAM/VRAM checks before model load  
✅ **Policy-driven cloud fallback** — explicit approval required, secrets never in code  
✅ **Unified CLI** — `ai-start`, `ai-stop`, `ai-health`, `ai-code`  

---

## 📦 Component Guide

**What each part does and why it's here:**

### 🔧 Core Scripts (`scripts/`)

| File | Purpose | Why It Exists |
|------|---------|---------------|
| **`Start-AI.ps1`** | Starts Ollama on port 12345, enforces single instance, creates firewall rules | Prevents the "multiple Ollama instances" problem that breaks tools and wastes VRAM |
| **`Start-VLLM.ps1`** | Runs vLLM (Docker) as the local backend on port 12345, health-checked and firewall-guarded like Ollama | Optional higher-throughput backend for NVIDIA GPU owners — called automatically by `Start-AI.ps1` when `preferredLocalProvider` is `vllm` |
| **`Get-BackendCapability.ps1`** | Detects whether vLLM is viable (NVIDIA GPU + Docker Desktop running) | Lets `Start-AI.ps1` only offer vLLM as a choice when it can actually work |
| **`Stop-AI.ps1`** | Kills all Ollama processes, clears session state, optionally removes firewall rules | Clean shutdown without leaving zombie processes or orphaned ports |
| **`profile-helpers.ps1`** | Provides `ai-start`, `ai-stop`, `ai-health`, `ai-code` CLI commands | Single source of truth for environment variables; no manual `export` commands |
| **`Invoke-CommitReview.ps1`** | Pre-commit hook that scans for secrets, API keys, PII | Prevents accidental data leakage to Git (the "don't commit your .env" problem) |

### ⚙️ Configuration (`config/`)

| File | Purpose | Why It Exists |
|------|---------|---------------|
| **`models.json`** | Registry of local models (sizes, capabilities, fallback order) | Tools know which model to use for coding vs. reasoning vs. fast tasks |
| **`provider-policy.json`** | Routing rules (local-first, cloud fallback, data privacy) | Explicit control over when/whether data leaves your machine |
| **`auth.json.template`** | Template for cloud provider API keys | Separates secrets from code; run `ai-auth-set <provider> <key>` to fill it in — never commit the real `auth.json` |
| **`opencode.json.template`** | Template for opencode.ai agent configuration | Pre-configures agents to use local Ollama endpoint |
| **`hermes-config.json.template`** | Template for the Hermes container's agent config | Configures Hermes's cloud-model settings before first run |
| **`jcode-config.toml.template`** | Template for the jcode agent configuration | Pre-configures jcode to use the local Ollama endpoint |
| **`pi-models.json.template`** | Template for Pi.dev's model registry | Mirrors `models.json` for the Pi.dev agent |

### 🛡️ Policies (`config/policies/`)

| File | Purpose | Why It Exists |
|------|---------|---------------|
| **`provider-policy.json`** | Defines local vs. cloud routing, data privacy rules | Ensures sensitive code never goes to cloud unless explicitly allowed |
| **`commit-policy.json`** | Patterns to block in commits (API keys, passwords, PII) | Automated security gate before `git commit` |

### 📚 Documentation (`docs/`)

| File | Purpose |
|------|---------|
| **`00-Artifact-Index.md`** | Complete manifest of all files and their purposes |
| **`01-Local-AI-Platform-Blueprint.md`** | High-level architecture and design decisions |
| **`02-Windows-Implementation-Guide.md`** | Windows-specific setup and troubleshooting |
| **`03-PowerShell-Module-Spec.md`** | API reference for `ai-*` commands |
| **`04-Security-Audit-Runbook.md`** | How to audit logs, rotate keys, respond to incidents |
| **`05-Provider-Fallback-Matrix.md`** | Decision matrix for when to use local vs. cloud |
| **`06-Model-Acquisition-Backlog.md`** | Zero-touch model auto-selection/pull backlog and review history |
| **`07-Quickstart-Playbook.md`** | Step-by-step operational playbook (start, switch models, troubleshoot) |
| **`08-Agent-CLI-Setup-Guide.md`** | Beginner-friendly, tested setup steps for every agent CLI (Pi.dev, opencode, jcode, Codex, Claude Code, aider, Copilot CLI, Gemini CLI) |
| **`09-Cross-Harness-Session-Resume.md`** | Resume work across Claude Code, Grok CLI, Pi CLI, and OpenCode without re-explaining context — how it works per tool, plus security notes |
| **`adr/`** | Architecture Decision Records — the "why" behind major choices (model acquisition placement, Ollama auto-install, vLLM backend option, cross-harness session resume) |

**New to Airlock?** [`tools/airlock-manual/index.html`](tools/airlock-manual/index.html) is a beginner-friendly, illustrated version of this README — plain-English definitions, an animated architecture diagram, every command with a runnable snippet and a real use case, and a deep dive into the memory service's RAG pipeline. Open it directly in a browser, no build step.

#### Configuring Agent CLIs

New to one of these tools, or want the full walkthrough with verified commands and troubleshooting for each? See [`docs/08-Agent-CLI-Setup-Guide.md`](docs/08-Agent-CLI-Setup-Guide.md) — this section is the condensed reference version.

The platform exposes an OpenAI-compatible **Chat Completions** endpoint at `http://127.0.0.1:12345/v1` (`ollama` as a dummy API key, real model names from `ai-models`) — and, on the installed Ollama build, also **OpenAI's Responses API** (`/v1/responses`) and **Anthropic's Messages API** (`/v1/messages`). Ollama's own published docs (ollama.readthedocs.io/en/openai) only document Chat Completions; the other two are real but undocumented there. Older Ollama installs may not have them — check yours before relying on the Codex/Claude Code/Copilot entries below:

```powershell
curl http://127.0.0.1:12345/v1/responses -d '{"model":"<any model from ai-models>","input":"hi"}'
```

A `404` means your Ollama predates these routes (upgrade, or stick to Pi.dev/opencode/jcode/aider below, which only need Chat Completions). A `200` means everything below applies. Every entry below was verified against the platform's actual running instance — a real prompt in, a real completion out — not just a matching HTTP shape.

**Pi.dev** — copy `config/pi-models.json.template` to `%USERPROFILE%\.pi\agent\models.json` and confirm its `ollama.baseUrl` matches the platform's port (default `12345`; edit both if you change `ai-start -Port`).

**opencode.ai** — copy `config/opencode.json.template` to `~/.config/opencode/opencode.json` for a global config, or to `opencode.json` in a project root for a project-scoped one. It already points `provider.ollama.options.baseURL` at `http://127.0.0.1:12345/v1` and sets `model` to `ollama/devstral-small-2:24b`. Run `opencode` from anywhere and it picks it up.

**jcode** — no template file; the `--no-api-key`/`--auth` flags this section used to document don't exist in current jcode (verified against a real install, jcode v0.65.0). The real command:
  ```powershell
  jcode provider add local-ollama --base-url "http://127.0.0.1:12345/v1" `
    --model "qwen2.5-coder:7b" --provider ollama `
    --set-default --model-catalog --overwrite
  ```
  `--provider ollama` is jcode's built-in provider type — it already knows Ollama needs no API key, so nothing else to pass. jcode has no per-project config — this writes into `%USERPROFILE%\.jcode\config.toml`.

**Codex CLI (OpenAI's)** — works, confirmed with a live `codex exec` round-trip against the platform. Codex's `wire_api` only supports `"responses"` (`wire_api = "chat"` is hard-rejected: "no longer supported"), so it needs the `/v1/responses` route from the check above. No template ships for this — Codex has no per-project config — add a provider block to `%USERPROFILE%\.codex\config.toml`:
  ```toml
  [model_providers.airlock]
  name = "airlock"
  base_url = "http://127.0.0.1:12345/v1"
  wire_api = "responses"

  model_provider = "airlock"
  model = "qwen2.5-coder:7b"
  ```
  Codex's own `--oss --local-provider ollama` flag also exists but targets Ollama's default port `11434`, not this platform's `12345` — use the config above instead if you've moved the platform's port with `ai-start -Port`.

**aider** — no config file needed; `ai-code` (in `profile-helpers.ps1`) already launches it with `--openai-api-base` pointed at the platform.

**Claude Code** — works too, confirmed with a live `claude -p` call that got a real completion back from the platform, not a connection error. Point it at `/v1/messages`:

  **Recommended — session-scoped, checked against a live endpoint, never persisted:**
  ```powershell
  ai-claude-on    # this shell only
  # ... use claude normally ...
  ai-claude-off   # or just close the shell — either way it doesn't outlive the session
  ```

  **Alternative — permanent, via `settings.json`'s `env` block:**
  ```json
  {
    "env": {
      "ANTHROPIC_BASE_URL": "http://127.0.0.1:12345",
      "ANTHROPIC_AUTH_TOKEN": "ollama"
    }
  }
  ```
  ⚠️ **This has no off switch of its own.** It applies to *every* Claude Code session on the machine — including ones with nothing to do with this platform — and stays in effect after `ai-stop`, a reboot, or a port change, until manually removed. With the platform down, Claude Code fails with `Connection refused — a firewall or proxy may be blocking it`, which points at the wrong subsystem entirely. Hit that error? Run `ai-doctor` — it detects exactly this and prints the fix — or use `ai-claude-on`/`ai-claude-off` instead so it can't happen.

  Ollama doesn't check the API key — any non-empty string works. Anthropic's own docs say they don't *support* routing Claude Code to non-Claude models through a gateway; that's a support-policy statement, not a technical block, and this repo's earlier "Claude Code cannot be pointed at this platform" claim was wrong — it was written against Ollama's documented API surface, which stops at Chat Completions, before testing found the undocumented `/v1/messages` route above. The repo previously also shipped a `claude-settings.json.template` inventing a fake settings schema (`api.ollama.baseUrl`/etc.); that's what caused the original base-url/token error and it's been deleted. This platform's own cloud-fallback path (`ai-auth-set anthropic <key>` + `cloudFallbackEnabled: true` in `provider-policy.json`) is unrelated — that talks to Anthropic's real API for genuine Claude models, unaffected either way.

  **Model choice matters more here than for the other tools above.** Claude Code's system prompt is large and its agentic loop assumes a competent instruction-following model. A quick test with a tiny model (`qwen2.5:0.5b`) connected fine but ignored the prompt and rambled — use something in the `qwen2.5-coder:7b`+ range (the same tier this platform already auto-selects for you), not a toy model.

**GitHub Copilot CLI** — works natively, no gateway trickery: GitHub added BYOK/local-model support in April 2026. Set these before launching `copilot` (env vars, not a config file):
  ```powershell
  $env:COPILOT_PROVIDER_BASE_URL = "http://127.0.0.1:12345/v1"
  $env:COPILOT_MODEL = "qwen2.5-coder:7b"
  copilot
  ```
  `COPILOT_PROVIDER_TYPE` defaults to `openai`, which is what Ollama speaks — no need to set it. `COPILOT_PROVIDER_API_KEY` isn't needed either, same reason as Claude Code above. GitHub's docs require the model to support tool calling and streaming (`qwen2.5-coder` does) and recommend 128k+ context for best results. Not installed on this machine, so unlike everything else in this section this one is unverified end-to-end here — the env-var mechanism itself is officially documented (GitHub's own docs), not guessed.

**Gemini CLI — does not work with this platform, and there's no config that fixes it.** `GOOGLE_GEMINI_BASE_URL` will redirect Gemini CLI's requests to any host, but the CLI still sends Google's own Gemini wire format there — and Ollama doesn't implement that shape (checked the installed binary directly: no `generateContent`/`v1beta`-style routes, only the OpenAI and Anthropic ones documented above). The CLI's own `gemini gemma` subcommand runs a *different* local model — Google's Gemma, via Google's own LiteRT-LM runtime — it's local, but it isn't this platform and doesn't proxy anywhere else. Community forks of Gemini CLI (`ollama-code`, `open-gemini-cli`) add real OpenAI-compatible routing, but that's a different tool than the officially-installed `gemini` CLI this section is about.

### 🧩 VS Code Extension (`src/extension.ts`)

Thin wrapper over the `ai-*` PowerShell helpers — status bar model indicator plus commands to start, stop, health-check, and switch models without leaving the editor. See [`EXTENSION.md`](EXTENSION.md) for setup and command list.

### 🔄 Cross-Harness Session Resume

Hit a limit in Claude Code, switch to Grok CLI, Pi CLI, or OpenCode, and pick up the same task without re-explaining it — a project-local snapshot file each tool reads automatically (or near-automatically; see the doc for per-tool specifics). See [`docs/09-Cross-Harness-Session-Resume.md`](docs/09-Cross-Harness-Session-Resume.md).

### 🤖 Hermes Agent (`hermes-container/`)

**What is Hermes?**

Hermes is a **sandboxed AI agent** for career operations (job applications, resume optimization, LinkedIn outreach) that runs in a Docker container.

**Why does it exist?**

| Problem | Hermes Solution |
|---------|-----------------|
| You want AI to help with job hunting, but you don't want your **personal files** (tax docs, family photos) exposed to the AI | Hermes runs in an isolated container that **only sees your career-ops repository**, not your Desktop/Documents |
| You need to use **cloud models** (GPT-4, Claude) for career tasks, but your **local code** must stay private | Hermes uses cloud models for career work; your local code stays on your machine |
| You want to **automate** job applications without running scripts on your main OS | Hermes is a Docker container with **dropped capabilities**, no network access to your LAN, and read-only mounts |

**How it works:**

```mermaid
flowchart LR
    subgraph "Host OS (Your Machine)"
        A[Your Personal Files] -. NOT ACCESSIBLE .-> B[Hermes Container]
        C[Local Code Repo] -. NOT ACCESSIBLE .-> B
        D[Career-Ops Repo] -->|Read-Only Mount| B
    end

    subgraph "Hermes Container"
        B --> E[Ollama Local Models]
        B --> F[Cloud Models via API]
        E --> G[Generate Cover Letter]
        F --> G
        G --> H[Output: job-applications/]
    end

    subgraph "You Extract"
        H --> I[Review & Submit]
    end

    style A fill:#f99
    style C fill:#f99
    style B fill:#9f9
    style H fill:#99f
```

**Usage:**

```powershell
# 1. Prepare your career-ops repo (separate from your code)
git clone git@github.com:yourusername/career-ops.git
cd career-ops

# 2. Add your resume, job descriptions, templates
# (This repo is the ONLY thing Hermes can see)

# 3. Start Hermes
cd ../airlock/hermes-container
.\run-hermes.ps1

# 4. Hermes generates job applications in output/
# 5. Review and submit manually
.\stop-hermes.ps1
```

**Security guarantees:**

- ✅ **Cannot access** your Desktop, Documents, Downloads
- ✅ **Cannot access** your local code repositories
- ✅ **Cannot access** your LAN (other containers, printers, NAS)
- ✅ **Cannot modify** your host filesystem (output is a Docker volume you extract)
- ✅ **All capabilities dropped** (no root, no network, no new privileges)

---

## 🏗️ Architecture

The big picture — the diagrams below this one cover backend selection, startup/shutdown, and the data model each in detail, so this one stays deliberately simple:

```mermaid
flowchart LR
    U([You]) -->|ai-start| P[Airlock picks<br/>one backend:<br/>Ollama or vLLM]
    P --> E["One stable endpoint<br/>127.0.0.1:12345/v1<br/>same either way"]
    E --> C["Your AI tool<br/>aider · Claude Code · opencode"]
    P -.->|always on| G["Firewall-blocked · single-instance only<br/>every action audit-logged"]
    E -.->|only if you enable it| CL["Cloud fallback<br/>(OpenRouter, OpenAI, Anthropic...)"]

    style P fill:#f9f,stroke:#333,stroke-width:3px
    style E fill:#9f9,stroke:#333,stroke-width:2px
```

**How to read the diagram below this point:** "Backend Selection Flowchart" is *how* Airlock picks Ollama vs. vLLM (the `P` box above, expanded). "Start/Stop State Lifecycle" is *what happens* when you run `ai-start`/`ai-stop`, in order. "Data Model" is the JSON files on disk and what each one holds. You don't need all three to use Airlock — they're here for when something doesn't match what you expected.

### Backend Selection Flowchart

```mermaid
flowchart LR
    A[Start-AI.ps1] --> B{First run?}
    B -->|Yes| C[Seed provider-policy.json<br/>from template]
    B -->|No| D[Read existing<br/>provider-policy.json]
    C --> E[Check vLLM viability]
    D --> F{Valid backend<br/>stored?}
    F -->|Yes, Ollama| G[Launch Ollama]
    F -->|Yes, vLLM| H[Launch vLLM]
    F -->|No/Invalid| E
    E --> I{NVIDIA GPU<br/>+ Docker running?}
    I -->|Yes| J["Prompt user:<br/>Ollama or vLLM?"]
    I -->|No| K[Default: Ollama]
    J --> L{User choice}
    L -->|Ollama| M[Persist 'ollama'<br/>to policy]
    L -->|vLLM| N[Persist 'vllm'<br/>to policy]
    K --> M
    M --> G
    N --> H
    H --> O{Health check<br/>passes?}
    O -->|Yes| P["Active: vLLM<br/>on 127.0.0.1:12345"]
    O -->|No| Q["Fall back to Ollama"]
    G --> R["Active: Ollama<br/>on 127.0.0.1:12345"]
    Q --> R

    style G fill:#9f9
    style P fill:#9f9
    style R fill:#9f9
    style H fill:#ff9
```

### Start/Stop State Lifecycle

```mermaid
sequenceDiagram
    participant User
    participant AI as Start-AI.ps1
    participant vLLM as Start-VLLM.ps1
    participant Ollama as Ollama
    participant Files as State Files
    
    User->>AI: ai-start
    AI->>Files: Check .active-port.json
    Files-->>AI: Not found (first run)
    AI->>AI: Read provider-policy.json
    AI->>AI: Backend selection logic
    
    alt vLLM chosen
        AI->>vLLM: Hand off to Start-VLLM.ps1
        vLLM->>vLLM: docker run vllm/vllm-openai
        vLLM->>vLLM: Poll /health endpoint
        vLLM->>Files: Write .active-port.json<br/>Write active-provider.json
        Files-->>AI: State written
        vLLM-->>AI: Exit 0
    else Ollama chosen (or vLLM fallback)
        AI->>Ollama: Start-AI.ps1 continues
        Ollama->>Ollama: Single instance check
        Ollama->>Ollama: Start ollama serve
        Ollama->>Files: Write .active-port.json<br/>Write active-provider.json
        Files-->>AI: State written
    end
    
    AI->>Files: Write audit log (SUCCESS)
    AI-->>User: Platform ready
    
    User->>User: Use local endpoint
    User->>User: http://127.0.0.1:12345/v1
    
    User->>User: ai-stop
    alt active-provider.json says vllm
        User->>vLLM: Stop-AI.ps1 detects vLLM
        vLLM->>vLLM: docker rm -f ai-platform-vllm
    else active-provider.json says ollama
        User->>Ollama: Stop-AI.ps1 kills Ollama
        Ollama->>Ollama: Kill olllama app & serve processes
    end
    
    User->>Files: Delete .active-port.json<br/>Delete active-provider.json
    Files-->>User: State cleared
    User-->>User: Session ended
```

### Data Model (State & Config Entities)

What each JSON file on disk actually holds, and how they relate. `provider-policy.json` is the persisted *intent* ("use vLLM if I can"); `active-provider.json` is the *live truth* of what's running right now — they're deliberately separate so a stale runtime state can never look like a changed user preference.

```mermaid
erDiagram
    PROVIDER_POLICY ||--o{ ACTIVE_PROVIDER : "backend choice read by Start-AI.ps1 to produce"
    PROVIDER_POLICY {
        string preferredLocalProvider "ollama or vllm"
        string preferredLocalModel
        bool cloudFallbackEnabled
        bool allowSensitiveDataToCloud
        array cloudProviderPriority
    }
    ACTIVE_PORT ||--|| ACTIVE_PROVIDER : "written and deleted together, every start/stop"
    ACTIVE_PORT {
        int port
        string model
        datetime started
    }
    ACTIVE_PROVIDER {
        string provider "ollama or vllm - ground truth for Stop-AI.ps1"
        string model
        string endpoint "http://127.0.0.1:12345/v1"
        string source "local or cloud"
        string reason
    }
    MODELS_REGISTRY ||--o{ ACTIVE_PROVIDER : "supplies model name/size for auto-selection"
    MODELS_REGISTRY {
        object localModels "name to size, params, role, tags"
        array fallbackOrder
    }
    AUTH_CONFIG ||--o{ ACTIVE_PROVIDER : "supplies cloud credentials when source=cloud"
    AUTH_CONFIG {
        string provider
        string key "never committed, gitignored"
    }
    COMMIT_POLICY ||--o{ AUDIT_LOG : "block/approve decisions logged to"
    COMMIT_POLICY {
        array alwaysBlockPatterns
        array requireApprovalPatterns
    }
    ACTIVE_PROVIDER ||--o{ AUDIT_LOG : "every state transition logged to"
    AUDIT_LOG {
        datetime timestampUtc
        string action
        string result "STARTED, SUCCESS, WARNING, FAILED"
        string provider
        string model
    }
```

---

## 🚀 Quick Start

### Prerequisites

- Windows 11
- [PowerShell 7+](https://github.com/PowerShell/PowerShell)
- [Ollama](https://ollama.ai) (installed, but **not running**)
- [Python 3.11+](https://www.python.org/) (for aider)
- [Git](https://git-scm.com/)

### Installation (1-line)

```powershell
irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex
```

This clones the repo to `~/.airlock-src` and runs `setup.ps1`, which copies scripts/config to `~/.ai-platform` and wires `profile-helpers.ps1` into your PowerShell profile. Restart PowerShell (or run `. $PROFILE`) afterward so the `ai-*` commands are available.

Like any `irm | iex` one-liner (rustup, Scoop, oh-my-posh use the same pattern), this runs code before you've read it — that's the convenience trade-off. If you'd rather review first, clone and inspect, then run `setup.ps1` yourself:

```powershell
git clone https://github.com/veeresh-bikkaneti/airlock.git
cd airlock
.\setup.ps1
```

`ollama pull <model>` isn't a required manual step either way — `ai-start` auto-detects your hardware and pulls the best-fitting model in the background the first time you run it (see [`06-Model-Acquisition-Backlog.md`](docs/06-Model-Acquisition-Backlog.md)). Pull one yourself first only if you want a specific model pinned via `ai-start -Model <name>`.

<details>
<summary>Fully manual install (no setup.ps1)</summary>

```powershell
New-Item -Path "$env:USERPROFILE\.ai-platform\scripts" -ItemType Directory -Force
New-Item -Path "$env:USERPROFILE\.ai-platform\config\policies" -ItemType Directory -Force
Copy-Item .\scripts\*.ps1 "$env:USERPROFILE\.ai-platform\scripts\" -Force
Copy-Item .\config\*.json "$env:USERPROFILE\.ai-platform\config\" -Force
Copy-Item .\config\policies\*.json "$env:USERPROFILE\.ai-platform\config\policies\" -Force
Copy-Item .\config\*.template "$env:USERPROFILE\.ai-platform\config\" -Force
Add-Content $PROFILE ". `"$env:USERPROFILE\.ai-platform\scripts\profile-helpers.ps1`""
```

</details>

### First Run

```powershell
# Start the platform (single-instance, hardened)
ai-start

# Expected output:
# ========================================
#   AI PLATFORM READY (Hardened)
#   Endpoint: http://127.0.0.1:12345/v1
#   Model   : devstral-small-2:24b
#   Bind    : 127.0.0.1 ONLY (no external)
#   Firewall: Inbound port 12345 BLOCKED
# ========================================
# Note: the Firewall line is conditional on admin privileges. Running as admin,
# you'll see "Inbound port 12345 BLOCKED" (shown above). Without admin, you'll
# see "NO RULE on port 12345 (defense-in-depth only — listener is loopback-only,
# not externally reachable either way)" instead — the rule just didn't get created,
# but nothing outside your machine could reach the port regardless.

# Check health
ai-health

# Start coding with aider
ai-code
```

---

## 📚 Commands Reference

| Command | Description |
|---------|-------------|
| `ai-start [-Model <name>] [-Backend ollama\|vllm] [-Force]` | Start the platform, kill any rogues. `-Backend` overrides/persists the saved backend choice (e.g. retry vLLM after a fallback) |
| `ai-stop [-CleanFirewall]` | Stop the active backend, clear state and any `ai-claude-on` redirect |
| `ai-health` | Full health check (processes, API, firewall, resources) |
| `ai-doctor` | Find dead `ANTHROPIC_*`/`OPENAI_*`/`COPILOT_*`/`GROK_*` redirects (any scope) pointing at a port nothing is listening on, and print the exact fix |
| `ai-port` | Show active port, model, and any background model-pull job status |
| `ai-provider` | Show active provider (local/cloud) |
| `ai-switch <model>` | Switch model mid-session (e.g., `ai-switch qwen3-coder:30b`) |
| `ai-claude-on` / `ai-claude-off` | Point Claude Code at the local platform for this shell only (liveness-checked, session-scoped) / undo it |
| `ai-code [-Model <name>]` | Launch aider against the active (or given) model, with `-Model` validated against `ollama list` |
| `ai-audit-last` | Show recent audit log entries |
| `ai-config` | Show full platform configuration |
| `ai-models` | List configured models and capabilities |
| `ai-policy` | Show provider routing policy |
| `ai-auth-set <provider> <key>` | Store API key for cloud fallback |
| `ai-hermes-start` | Launch containerized Hermes agent |
| `ai-hermes-stop` | Stop Hermes and extract output |
| `ai-memory-start` | Start memory service (FastAPI, Chroma vector DB, LangGraph) |
| `ai-memory-stop` | Stop memory service |
| `ai-memory-status` | Show memory service status (process, API health, firewall, routing) |
| `ai-memory-on` | Route clients through memory service (retrieve → inject → forward) |
| `ai-memory-off` | Revert clients to direct backend calls (disable memory routing) |

---

## 🔐 Security Model

### Default: Local Only, Fail Closed

```mermaid
flowchart LR
    A[User Request] --> B{Policy Check}
    B -->|CloudFallback=FALSE| C[Local Ollama Only]
    B -->|CloudFallback=TRUE| D{SecretVault Key?}
    D -->|Found| E[Cloud Provider]
    D -->|Missing| F[Fail Closed - Block]
    C --> G[127.0.0.1:12345]
    G --> H[Firewall: Inbound Blocked]
```

### Security Features

1. **Single-instance enforcement** — prevents resource conflicts
2. **Firewall guard** — blocks inbound traffic to Ollama port
3. **Secret isolation** — API keys stored via `ai-auth-set` in `~/.ai-platform/config/auth.json`, gitignored, never in code
4. **Audit logging** — every request logged with timestamp, user, model, provider
5. **Fail-closed policy** — missing secrets = no cloud fallback
6. **Model digest verification** — ensures model integrity

---

## 🌐 Local + Cloud Hybrid

### Configuration

Edit `config/policies/provider-policy.json`:

```json
{
  "cloudFallbackEnabled": false,
  "allowSensitiveDataToCloud": false,
  "preferredLocalModel": "devstral-small-2:24b",
  "localFallbackModels": ["qwen3-coder:30b", "qwen2.5-coder:7b"],
  "cloudProviderPriority": ["openrouter", "openai", "anthropic"],
  "defaultCloudModels": {
    "openrouter": "openai/gpt-4.1-mini",
    "openai": "gpt-4.1-mini",
    "anthropic": "claude-3-5-sonnet-latest"
  }
}
```

### Enable Cloud Fallback (Optional)

```powershell
# 1. Set policy to allow cloud
# Edit: config/policies/provider-policy.json
# Set: "cloudFallbackEnabled": true

# 2. Store API key securely
ai-auth-set openrouter sk-or-v1-your-key-here

# 3. Start platform
ai-start

# Now if local model fails, it will fall back to cloud (with audit)
```

---

## 📊 Architecture Files

```
airlock/
├── README.md                     # This file
├── PLAYBOOK.md                   # Step-by-step operational playbook
├── LICENSE                       # MIT License
├── install.ps1                   # 1-line remote installer (irm ... | iex): clones + runs setup.ps1
├── setup.ps1                     # Local installer (deploys to ~/.ai-platform)
├── Start-AI.bat / Stop-AI.bat    # Double-click wrappers around the .ps1 scripts
├── main.py                       # Demo script for testing the OpenAI-compatible endpoint
├── requirements.txt              # Python dependencies for main.py
├── package.json / tsconfig.json  # VS Code extension build config
├── src/
│   └── extension.ts              # VS Code extension: status bar, start/stop/switch commands
├── scripts/
│   ├── Start-AI.ps1              # Main startup (hardened, single-instance, backend chooser)
│   ├── Start-VLLM.ps1            # Optional vLLM backend (Docker, NVIDIA GPU)
│   ├── Get-BackendCapability.ps1 # Detects vLLM viability (GPU + Docker)
│   ├── Get-ModelAcquisition.ps1  # Hardware detection + auto model pull (Ollama/HF)
│   ├── Stop-AI.ps1               # Clean shutdown (whichever backend is active)
│   ├── Start-MemoryService.ps1   # Starts memory service (FastAPI, Chroma, LangGraph)
│   ├── Stop-MemoryService.ps1    # Stops memory service
│   ├── profile-helpers.ps1       # CLI helpers (ai-start, ai-code, ai-health, ai-memory-*, etc.)
│   ├── Invoke-CommitReview.ps1   # Pre-commit security gate
│   └── Test-*.ps1                # Self-checks for model selection / capability logic
├── config/
│   ├── models.json               # Model registry (capabilities, sizes)
│   ├── policies/
│   │   ├── provider-policy.json  # Routing rules (local/cloud, preferredLocalProvider)
│   │   └── commit-policy.json    # Patterns blocked/needing approval before commit
│   └── *.template                # Copy-and-fill templates: auth, opencode,
│                                  # hermes-config, jcode-config, pi-models
├── docs/
│   ├── 00-Artifact-Index.md
│   ├── 01-Local-AI-Platform-Blueprint.md
│   ├── 02-Windows-Implementation-Guide.md
│   ├── 03-PowerShell-Module-Spec.md
│   ├── 04-Security-Audit-Runbook.md
│   ├── 05-Provider-Fallback-Matrix.md
│   ├── 06-Model-Acquisition-Backlog.md
│   ├── 07-Quickstart-Playbook.md
│   ├── 08-Agent-CLI-Setup-Guide.md
│   ├── COMPONENTS.md
│   └── adr/                      # Architecture Decision Records
├── hermes-container/             # Sandboxed agent for job applications
│   ├── README.md
│   ├── PLAYBOOK.md
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── run-hermes.ps1
│   └── stop-hermes.ps1
├── memory-service/                # FastAPI app: vector DB + RAG + LangGraph session memory
│   ├── app/
│   │   ├── main.py                # FastAPI routes: /health, /v1/memory/*, /v1/chat/completions proxy
│   │   ├── memory_store.py        # Chroma vector DB (remember/recall)
│   │   ├── graph.py                # LangGraph retrieve -> inject -> forward pipeline
│   │   ├── checkpointer.py        # Per-session short-term/working memory
│   │   ├── embeddings.py          # Ollama /api/embeddings client
│   │   ├── proxy.py                # Forwards to the real backend, tracks active provider
│   │   ├── audit.py                # Structured audit logging
│   │   └── config.py
│   ├── tests/
│   └── requirements.txt
└── tools/
    └── 3d-system-visualizer/      # Standalone Three.js system-design + workflow visualizer
        └── index.html
```

---

## 🧊 3D System Visualizer

Standalone, single-file Three.js scene (`tools/3d-system-visualizer/index.html`) for visualizing a system's services, data stores, and edges as a 3D node graph — with animated workflow playback (a packet travels the actual call path, step by step) and built-in scene validation (catches edges referencing missing nodes or steps with no matching edge, reported per flow).

No build step, no dependencies to install — it pulls Three.js from a CDN via an import map.

![3D system visualizer node graph](tools/3d-system-visualizer/preview.png)

**Run it locally:**

```powershell
# from repo root
python -m http.server 8347 --directory tools/3d-system-visualizer
# or
npx serve tools/3d-system-visualizer
```

Open `http://localhost:8347` and click a workflow button in the top-left panel to watch it animate through the graph.

> Import maps require a real HTTP origin — opening `index.html` directly via `file://` will fail to load the ES modules.

**Load your own scene:** the "Scene" panel picks between scenes listed in `tools/3d-system-visualizer/scenes/manifest.json`, accepts `?scene=scenes/your-file.json` on the URL, or a local file via "Load file…" — any scene using the same `{nodes, edges, flows}` schema as `scenes/ecommerce-demo.json` works. A bad or malformed scene shows an error instead of clearing the one currently on screen.

**Inspect a node or edge:** click any box or connector to open a panel with its metadata — nodes can carry `description`, `owner`, and `status` (`healthy`/`degraded`/`down`); edges can carry `protocol` and `latencyMs`. A `degraded` or `down` node also glows amber or red in the scene itself, so problems read at a glance without clicking anything.

**Flow animation:** each running workflow shows a glowing head with a short fading trail (not a single bare dot), colored cool-to-warm by the edge's `latencyMs` where the schema provides it (falls back to the original amber if not). Purely visual — no schema changes required for existing scenes.

**See this platform's own real activity, not just the fictional demo:** `scenes/Generate-LiveScene.ps1` reads `~/.ai-platform/logs/<date>.jsonl` (this platform's own audit log) and turns real recorded actions — backend selection, model pulls, firewall guards, start/stop — into a scene using the same schema, registering it in `manifest.json` automatically. Re-run it after using the platform to refresh with whatever happened since; it's an on-demand snapshot, not a live stream.

```powershell
.\tools\3d-system-visualizer\scenes\Generate-LiveScene.ps1
# then pick "local-ai-platform (live)" from the Scene dropdown, or:
# ?scene=scenes/local-ai-platform-live.json
```

---

## 🧪 Testing

### Verify Installation

```powershell
# 1. Check health
ai-health

# Expected: All green (2 processes, API healthy, firewall blocked, RAM >20%)

# 2. Test model switch
ai-switch qwen3-coder:30b
ai-switch deepseek-r1:14b

# 3. Check audit logs
ai-audit-last

# 4. Test cloud fallback (if enabled)
# Temporarily stop Ollama
ai-stop
# Try ai-code — should fail or fall back to cloud (depending on policy)
```

### Stress Test Single-Instance Enforcement

```powershell
# Start multiple times — should detect and reuse existing
ai-start
ai-start
ai-start

# Should see: "Found Ollama on port 12345" each time (no duplicates)

# Force restart
ai-start -Force

# Should see: "Force: killing for clean restart"
```

---

## 🛠️ Troubleshooting

### "Multiple instances detected"

```powershell
# Clean kill and restart
ai-stop
ai-start -Force
```

### "Firewall rule could not be created"

Run PowerShell as **Administrator**:

```powershell
New-NetFirewallRule -DisplayName "AI-Platform-Ollama-Block-12345" `
    -Direction Inbound -Action Block -Protocol TCP -LocalPort 12345
```

### "Model not found locally"

```powershell
# Pull the model
ollama pull devstral-small-2:24b

# Or switch to available model
ai-switch qwen2.5-coder:7b
```

### "Low VRAM / OOM errors"

```powershell
# Use smaller model
ai-switch qwen2.5-coder:7b

# Or check available memory
ai-health
```

---

## 🤝 Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing`)
5. Open a Pull Request

### Development Guidelines

- Always test with `ai-start -Force` before committing
- Ensure no secrets in code (use `config/auth.json.template` etc. for examples — never commit the filled-in versions)
- Add audit logging for new actions
- Update `docs/` for significant changes

---

## 📄 License

MIT License — see [LICENSE](LICENSE)

---

## 🙏 Acknowledgments

- [Ollama](https://ollama.ai) for local LLM inference
- [aider](https://aider.chat) for AI-assisted coding
- [opencode.ai](https://opencode.ai) for agent orchestration
- [PowerShell](https://microsoft.com/powershell) for cross-platform scripting

---

**Built with ❤️ for secure, local-first AI development.**