# Airlock Playbook

**Step-by-step workflows for secure, local-first AI development with optional cloud fallback.**

---

## Table of Contents

1. [Getting Started](#getting-started)
2. [Daily Workflow](#daily-workflow)
3. [Model Management](#model-management)
4. [Cloud Fallback Setup](#cloud-fallback-setup)
5. [Security Operations](#security-operations)
6. [Troubleshooting Guide](#troubleshooting-guide)
7. [Advanced Workflows](#advanced-workflows)

---

## Getting Started

### First-Time Setup (1-line installer)

```powershell
# One-line installer (recommended)
irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex
```

This clones the repo to `~/.airlock-src`, runs `setup.ps1`, and wires `profile-helpers.ps1` into your PowerShell profile. Restart PowerShell (or run `. $PROFILE`) to load the `ai-*` commands.

Prefer to review first? Clone and run `setup.ps1` yourself:

```powershell
git clone https://github.com/veeresh-bikkaneti/airlock.git
cd airlock
.\setup.ps1
```

### Verify Installation

```powershell
# Start the platform (auto-pulls a model on first run based on hardware)
ai-start

# Expected output:
# ========================================
#   AI PLATFORM READY (Hardened)
#   Endpoint: http://127.0.0.1:12345/v1
#   Model   : devstral-small-2:24b
#   Bind    : 127.0.0.1 ONLY (no external)
#   Firewall: Inbound port 12345 BLOCKED (admin) / NO RULE (defense-in-depth, loopback-only)
# ========================================
# Note: Firewall status is conditional. If you're running as admin, the platform
# creates a BLOCK rule. If not, no rule is created, but the listener is still
# loopback-only and unreachable from outside.

# Check health
ai-health

# Start coding with aider
ai-code
```

---

## Daily Workflow

### Morning: Start Your AI Session

```powershell
# Start the platform (single command)
ai-start

# Check health
ai-health

# Expected: All green indicators
# - Processes: 1 (Ollama or vLLM)
# - API: HEALTHY
# - Firewall: BLOCKED (if admin) or NO RULE (defense-in-depth: loopback-only listener)
# - RAM: >20% free
# - VRAM: >4GB free
```

### During the Day: Coding Sessions

#### Option 1: aider (CLI-based AI coding)

```powershell
# Launch aider with current model
ai-code

# aider starts with Ollama backend automatically
# No manual configuration needed!
```

#### Option 2: opencode.ai (Agent-based)

```powershell
# opencode reads config from .opencode/opencode.json
# Already configured to use http://127.0.0.1:12345/v1

# Just run opencode as normal
opencode
```

#### Option 3: Direct API calls

```python
import openai

openai.api_base = "http://127.0.0.1:12345/v1"
openai.api_key = "ollama"  # Dummy key, Ollama doesn't validate

response = openai.ChatCompletion.create(
    model="devstral-small-2:24b",
    messages=[{"role": "user", "content": "Explain this code"}],
)
```

### Switching Models Mid-Session

```powershell
# Check available models
ollama list

# Switch to a different model
ai-switch qwen3-coder:30b

# Verify
ai-provider

# Output:
# Provider: ollama
# Model   : qwen3-coder:30b
# Endpoint: http://127.0.0.1:12345/v1
```

### End of Day: Clean Shutdown

```powershell
# Stop the platform (clears state, kills processes)
ai-stop

# Verify
Get-Process ollama*  # Should return nothing
```

---

## Model Management

### Pulling New Models

```powershell
# List available models
ollama list

# Pull a new model
ollama pull qwen3:14b

# Pull a smaller/faster model
ollama pull qwen2.5-coder:7b

# Pull a reasoning model
ollama pull deepseek-r1:14b
```

### Recommended Model Sizes

| Use Case | Model | Size | VRAM Required | Speed |
|----------|-------|------|---------------|-------|
| **Lightweight / Budget** | qwen2.5-coder:7b | 4.7 GB | 8 GB | Fast ⚡ |
| **Default / Balanced** | devstral-small-2:24b | 14 GB | 16 GB | Medium ⚡⚡ |
| **Complex / Production** | qwen3-coder:30b | 18 GB | 24 GB | Slow ⚡⚡⚡ |
| **Reasoning / Math** | deepseek-r1:14b | 9 GB | 16 GB | Medium ⚡⚡ |

### Model Registry

Edit `config/models.json` to add custom models:

```json
{
  "localModels": {
    "my-custom-model:latest": {
      "size": "~8 GB",
      "parameters": "8B",
      "contextWindow": 32768,
      "maxOutputTokens": 16384,
      "role": "coding",
      "tags": ["coding", "fast"],
      "supportsFunctionCalling": true
    }
  },
  "fallbackOrder": ["my-custom-model:latest", "qwen2.5-coder:7b"]
}
```

### Backend Selection (Optional vLLM for GPU Owners)

If you have an NVIDIA GPU and Docker Desktop running, `ai-start` will prompt you once to choose between **Ollama** or **vLLM**. Your choice is persisted to `config/policies/provider-policy.json` so future starts use the same backend.

- **Ollama**: Straightforward, no Docker required, good for most use cases.
- **vLLM**: Higher throughput for batch/parallel requests, Docker-based, NVIDIA GPU only.

See [`docs/07-Quickstart-Playbook.md`](docs/07-Quickstart-Playbook.md) for detailed backend comparison and performance tuning.

---

## Cloud Fallback Setup

### Why Cloud Fallback?

- **Local model too small** for complex tasks
- **GPU out of memory** — fall back to cloud
- **Need latest models** (GPT-4, Claude 3.5)
- **Emergency backup** when local fails

### Step 1: Enable Policy

Edit `config/policies/provider-policy.json`:

```json
{
  "cloudFallbackEnabled": true,
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

### Step 2: Store API Keys

```powershell
# Store keys (writes to ~/.ai-platform/config/auth.json, gitignored, never committed)
ai-auth-set openrouter sk-or-v1-your-openrouter-key
ai-auth-set openai sk-your-openai-key
ai-auth-set anthropic sk-anthropic-key

# Verify
ai-auth
```

`ai-start` also checks for a registered PowerShell SecretManagement vault named `AIVault` (`Get-SecretVault -Name AIVault`) and logs whether it's present — that check is informational only, nothing currently reads keys from it. `ai-auth-set` above is the actual, working key storage.

### Step 3: Test Fallback

```powershell
# Start platform
ai-start

# Simulate local failure (stop Ollama)
ai-stop

# Try to use AI — should fall back to cloud (if policy allows)
ai-code

# Expected: Uses cloud provider instead of failing
```

### Cloud Provider Comparison

| Provider | Best For | Cost | Privacy |
|----------|----------|------|---------|
| **OpenRouter** | Aggregated access, multiple models | $$ | Good |
| **OpenAI** | GPT-4, most reliable | $$$ | Good |
| **Anthropic** | Claude 3.5, reasoning | $$$ | Good |
| **Google** | Gemini, fast inference | $$ | Medium |
| **Azure OpenAI** | Enterprise compliance | $$$$ | Excellent |

---

## Memory Service (Optional Vector DB + RAG)

The memory service adds persistent retrieval-augmented generation (RAG) and session memory on top of your backend model.

### Enable Memory Service

```powershell
# Start the memory service (FastAPI + Chroma vector DB + LangGraph)
ai-memory-start

# Check status (processes, API health, firewall, routing)
ai-memory-status

# Route clients through memory (retrieve → inject → forward to backend)
ai-memory-on

# Stop routing through memory and revert to direct backend calls
ai-memory-off

# Stop the memory service
ai-memory-stop
```

### Important: Ollama-Only Constraint

Memory service **only works with Ollama** — it needs Ollama's `/api/embeddings` endpoint to generate embeddings for vector storage. If you're using vLLM as your active backend, the memory service degrades to a no-op (logs a warning, retrieval/persist skipped) rather than crashing or falling back to an external embedding API. Switch to Ollama if you need memory features.

---

## Security Operations

### Pre-Commit Security Gate

```powershell
# Run before git commit
.\scripts\Invoke-CommitReview.ps1

# Checks for:
# - API keys / secrets
# - PII (emails, phone numbers)
# - Sensitive patterns (AWS keys, passwords)
# - Policy violations
```

### Audit Log Review

```powershell
# View recent activity
ai-audit-last

# View specific day's logs
Get-Content "$env:USERPROFILE\.ai-platform\logs\2026-06-28.jsonl" | ConvertFrom-Json

# Search for specific actions
Get-Content "$env:USERPROFILE\.ai-platform\logs\*.jsonl" | ConvertFrom-Json |
    Where-Object { $_.action -eq "ModelSwitch" }
```

### Firewall Rule Management

```powershell
# Check firewall status
ai-health

# View all AI platform rules
Get-NetFirewallRule -DisplayName "AI-Platform-*"

# Remove firewall rules (if needed)
ai-stop -CleanFirewall

# Manually add rule (Admin PowerShell)
New-NetFirewallRule -DisplayName "AI-Platform-Ollama-Block-12345" `
    -Direction Inbound -Action Block -Protocol TCP -LocalPort 12345
```

### Secret Rotation

```powershell
# Rotate an API key
ai-auth-set openrouter sk-new-key-after-rotation

# Verify old key is gone
ai-auth

# Audit log shows rotation
ai-audit-last
```

---

## Troubleshooting Guide

### Problem: "Multiple instances detected"

**Symptoms:**
```
WARNING: 3 Ollama processes detected (possible duplicate instances)
```

**Solution:**
```powershell
# Force kill all instances
ai-stop

# Clean restart
ai-start -Force

# Verify single instance
ai-health
```

### Problem: "Firewall rule could not be created"

**Symptoms:**
```
WARNING: Could not create firewall rule (needs admin?)
```

**Solution:**
```powershell
# Run PowerShell as Administrator
New-NetFirewallRule -DisplayName "AI-Platform-Ollama-Block-12345" `
    -Direction Inbound -Action Block -Protocol TCP -LocalPort 12345

# Or manually via Windows Defender Firewall GUI
```

### Problem: "Model not found locally"

**Symptoms:**
```
Model 'devstral-small-2:24b' not found locally.
```

**Solution:**
```powershell
# Pull the model
ollama pull devstral-small-2:24b

# Or switch to available model
ai-switch qwen2.5-coder:7b

# Check what's available
ollama list
```

### Problem: "Out of memory / OOM"

**Symptoms:**
```
Error: CUDA out of memory
Error: Failed to load model
```

**Solution:**
```powershell
# Check resources
ai-health

# Switch to smaller model
ai-switch qwen2.5-coder:7b

# Free up RAM
# - Close browser tabs
# - Close other GPU apps (VS Code, Docker, etc.)

# Check disk space (models need 5-45 GB)
Get-PSDrive C | Select-Object Used, Free
```

### Problem: "API unreachable"

**Symptoms:**
```
Connection refused to http://127.0.0.1:12345/v1
```

**Solution:**
```powershell
# Check if Ollama is running
Get-Process ollama*

# Check port
Test-NetConnection -ComputerName 127.0.0.1 -Port 12345

# Restart
ai-stop
ai-start

# Verify
curl http://127.0.0.1:12345/api/tags
```

**If Ollama is running but on the wrong port:** `.active-port.json` only gets
updated by `ai-start`/`ai-stop`. If Ollama was started outside that flow (tray
autostart, manual `ollama serve`), it binds its default port (11434) while the
state file still claims whatever port the last `ai-start` used. `ai-health`
reads the state file, not the real listener, so it will report a clean
`UNHEALTHY` on a port nothing is bound to. Confirm what Ollama is actually
listening on before assuming it's down:

```powershell
Get-NetTCPConnection -State Listen | Where-Object {
    $_.OwningProcess -in (Get-Process ollama* -ErrorAction SilentlyContinue).Id
} | Select-Object LocalPort, OwningProcess

# If it's listening on 11434 instead of the state-file port:
ai-stop
ai-start
```

### Problem: "Cloud fallback not working"

**Symptoms:**
```
Cloud fallback failed even though policy allows it
```

**Solution:**
```powershell
# Check policy
ai-policy

# Verify secrets and API keys
ai-auth

# Check logs for specific error
ai-audit-last
```

---

## Advanced Workflows

### Multi-Model Pipeline

```powershell
# Use different models for different tasks

# 1. Fast model for code completion
ai-switch qwen2.5-coder:7b
# ... do quick edits ...

# 2. Large model for complex refactoring
ai-switch qwen3-coder:30b
# ... do heavy lifting ...

# 3. Reasoning model for architecture decisions
ai-switch deepseek-r1:14b
# ... think through design ...
```

### Automated Testing with Local AI

```python
# tests/test_with_ollama.py
import openai
import pytest

openai.api_base = "http://127.0.0.1:12345/v1"
openai.api_key = "ollama"

def test_code_generation():
    response = openai.ChatCompletion.create(
        model="qwen2.5-coder:7b",
        messages=[{"role": "user", "content": "Write a Python function to add two numbers"}],
    )
    assert "def" in response.choices[0].message["content"]
```

### CI/CD Integration

```yaml
# .github/workflows/ai-review.yml
name: AI Code Review

on: [pull_request]

jobs:
  ai-review:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v3
      
      # Note: ollama/setup@v1 below is illustrative pseudocode — verify the actual
      # GitHub Action name before using in production CI. This is not a confirmed real action.
      - name: Setup Ollama
        uses: ollama/setup@v1
      
      - name: Pull model
        run: ollama pull qwen2.5-coder:7b
      
      - name: Run AI review
        run: |
          ollama serve &
          Sleep 10
          python scripts/ai_review.py
```

### Hermes Agent for Job Applications

```powershell
# Run sandboxed Hermes agent for career operations

# Start Hermes (isolated container)
ai-hermes-start

# Hermes uses local models, can't access your personal files
# Only sees your career-ops repository

# When done, stop and extract output
ai-hermes-stop

# Output extracted to: hermes-container/output/
```

### Custom Model Fine-tuning

Ollama does not have a built-in `ollama fine-tune` command. Instead, fine-tune models externally using tools like Unsloth or Axolotl, then import the result:

```bash
# Create a Modelfile pointing to your fine-tuned GGUF model
cat > Modelfile << EOF
FROM /path/to/your-finetuned-model.gguf
EOF

# Import it into Ollama
ollama create my-custom-model -f Modelfile

# Test
ollama run my-custom-model "Explain this code pattern"
```

---

## Performance Tuning

### Optimize for Your Hardware

**Low RAM (<16 GB):**
```json
// config/models.json
{
  "preferredLocalModel": "qwen2.5-coder:7b",
  "localFallbackModels": []
}
```

**High VRAM (24 GB+):**
```json
{
  "preferredLocalModel": "qwen3-coder:30b",
  "localFallbackModels": ["devstral-small-2:24b"]
}
```

**No GPU (CPU only):**
```powershell
# Use smallest model
ollama pull qwen2.5-coder:7b
ai-switch qwen2.5-coder:7b

# Set OLLAMA_NUM_GPU=0 to force CPU
$env:OLLAMA_NUM_GPU = "0"
```

### Context Window Optimization

Create `~/.ollama/modelfile`:

```
FROM devstral-small-2:24b
PARAMETER num_ctx 8192
PARAMETER num_batch 512
```

Then rebuild:
```bash
ollama create devstral-small-2:24b -f ~/.ollama/modelfile
```

---

## Contributing

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

**Happy coding! 🚀**