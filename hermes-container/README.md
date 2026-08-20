# Hermes Agent Container

A sandboxed AI agent that helps you apply for jobs using the [career-ops](https://github.com/your-org/career-ops) platform. Your personal files stay private: Hermes only sees your career-ops repo.

> **Not yet live-tested.** Unlike the agent CLIs in [`docs/08-Agent-CLI-Setup-Guide.md`](../docs/08-Agent-CLI-Setup-Guide.md) (each verified with a real round trip against a running Airlock instance), this container hasn't been built and run end-to-end as part of that testing pass. Everything below is the documented/intended behavior, not confirmed behavior. Treat it as such until someone actually runs `run-hermes.ps1` against a live Docker Desktop and checks the security guarantees hold. TODO: test this.

## What this does

- Runs the pi.dev Hermes agent inside a locked-down Docker container
- Uses your local Ollama models (devstral-small-2, qwen3-coder, deepseek-r1, etc.)
- Optionally uses NVIDIA NIM cloud models for heavier tasks
- Gets read-only access to your career-ops repo
- Writes output to a Docker volume, not mixed with your source files

## Security guarantees

| What | Access |
|---|---|
| Your Desktop, Documents, Photos | None (container can't reach them) |
| Career-ops repo | Read-only, can't modify your source |
| Generated output | Docker volume only, you choose when to extract |
| Other containers / host processes | Blocked by network policy |
| System privileges | All capabilities dropped |

## Prerequisites

1. [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows)
2. [Ollama](https://ollama.com/) installed and running locally
3. Your [career-ops](https://github.com/your-org/career-ops) repo cloned somewhere

## Quick Start

```powershell
# 1. Make sure Airlock's Ollama is running
ai-start

# 2. Pull at least one model (if you haven't already)
ollama pull devstral-small-2:24b

# 3. (recommended) Start the tool-call proxy - fixes unreliable tool-calling
#    on small models. Without it, tool calls may come back as plain text.
ai-tool-proxy-start

# 4. Launch Hermes
cd C:\path\to\local-ai-setup\hermes-container
.\run-hermes.ps1

# 4. Hermes opens in interactive mode. Try:
#    "Review my CV and suggest improvements"
#    "Scan my job applications for gaps"
#    "Generate a cover letter for the role at portal X"

# 5. When done, type /exit and run:
.\stop-hermes.ps1
```

## With NVIDIA NIM (cloud models)

```powershell
# Get your free key: https://build.nvidia.com/explore/discover
.\run-hermes.ps1 -NimApiKey "nvapi-..."
```

## With a different repo

```powershell
.\run-hermes.ps1 -CareerOpsRepo "C:\my-projects\my-career-ops"
```

## Available models

| Model | Size | Type | Provider |
|---|---|---|---|
| devstral-small-2:24b | 15 GB | Preferred coding | Ollama (local) |
| qwen3-coder:30b | 18 GB | Large coding | Ollama (local) |
| deepseek-r1:14b | 9 GB | Deep reasoning | Ollama (local) |
| qwen2.5-coder:7b | 4.7 GB | Fast coding | Ollama (local) |
| qwen3:14b | 9 GB | General purpose | Ollama (local) |
| Nemotron Ultra 253B | Cloud | Enterprise quality | NVIDIA NIM |
| DeepSeek V4 Pro | Cloud | Advanced reasoning | NVIDIA NIM |

## Troubleshooting

**"Docker is not running"**: start Docker Desktop from the Start menu.

**"Ollama is not running"**: run `ai-start` in a terminal, not `ollama serve` (Airlock's own `ollama` wrapper blocks that command and tells you the same thing).

**Tool calls coming back as plain text instead of working**: the tool-call proxy isn't running. Run `ai-tool-proxy-start` and restart Hermes.

**"Model not found"**: pull it first with `ollama pull <model-name>`.

**"Permission denied" errors from docker**: the container runs with dropped capabilities and a read-only filesystem. That's intentional.

**Output files not appearing**: run `.\stop-hermes.ps1` to extract output to your repo.

## Files

| File | Purpose |
|---|---|
| `run-hermes.ps1` | Build and launch the container |
| `stop-hermes.ps1` | Stop container and extract output |
| `docker-compose.yml` | Container definition |
| `Dockerfile` | Image build instructions |
| `entrypoint.sh` | Container startup script |
| `config/models.json` | pi.dev model configuration |
| `.env.example` | Environment variable template |
| `PLAYBOOK.md` | Step-by-step job application guide |