# Airlock Architecture

*How the pieces fit together — in plain English.*

---

## The Big Picture

```
┌─────────────────────────────────────────────────────────────────┐
│                        YOUR WINDOWS PC                          │
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐ │
│  │   ai-start      │    │  ai-agent-start │    │  ai-setup     │ │
│  │   (Chat Door)   │    │  (Coding Door)  │    │  (Interactive)│ │
│  └────────┬────────┘    └────────┬────────┘    └──────┬────────┘ │
│           │                      │                      │         │
│           ▼                      ▼                      ▼         │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                  profile-helpers.ps1                        │ │
│  │         (All ai-* commands, state management)               │ │
│  └────────────────────────────┬────────────────────────────────┘ │
│                               │                                  │
│           ┌───────────────────┼───────────────────┐             │
│           ▼                   ▼                   ▼             │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐  │
│  │   Ollama        │ │   llama-server  │ │   vLLM (Docker) │  │
│  │   (Chat)        │ │   (Coding)      │ │   (Optional)    │  │
│  │   Port 12345    │ │   Dynamic Port  │ │   Port 12345    │  │
│  └────────┬────────┘ └────────┬────────┘ └────────┬────────┘  │
│           │                   │                   │            │
│           └───────────────────┼───────────────────┘            │
│                               ▼                                │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              OpenAI-Compatible Endpoint                     │ │
│  │         http://127.0.0.1:12345/v1                           │ │
│  │    + /v1/responses (OpenAI)  +  /v1/messages (Anthropic)   │ │
│  └────────────────────────────┬────────────────────────────────┘ │
│                               │                                  │
│           ┌───────────────────┼───────────────────┐             │
│           ▼                   ▼                   ▼             │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐      │
│  │   aider     │     │  Claude Code │     │  opencode   │      │
│  │  (ai-code)  │     │ (ai-claude-  │     │ (ai-opencode)│      │
│  │             │     │   on/off)    │     │             │      │
│  └─────────────┘     └─────────────┘     └─────────────┘      │
│                                                               │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Supporting Services (Optional)                             │ │
│  │  • Memory Service (FastAPI + Chroma + LangGraph) :12346    │ │
│  │  • Tool-Call Proxy (Grammar-constrained) :12347            │ │
│  │  • Hermes Container (Career-ops sandbox)                    │ │
│  │  • 3D Visualizer (Three.js) :8347                          │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. The Two Doors

| Door | Entry Point | What It Does |
|------|-------------|--------------|
| **Chat** | `ai-start` | Starts Ollama or vLLM on port 12345. Single-instance, firewall-guarded, audit-logged. Auto-picks model for your VRAM. |
| **Coding** | `ai-agent-start` / `ai-opencode` | Sizes Unsloth Dynamic 3.0 to *your* free VRAM → downloads GGUF → starts llama-server → runs live Pi 3/3 contract → publishes certificate. |

**Why two doors?** Chat doesn't need tool-calling. Coding does. Mixing them means broken tool calls in chat or oversized models for coding. Two doors = honest capabilities.

### 2. The State Machine

Airlock is a state machine. Every run goes through:

```
START → CHECK LOCK → SELECT BACKEND → VERIFY HEALTH → PUBLISH STATE → READY
  │                                                          │
  └────────────────── STOP → CLEAR STATE ←───────────────────┘
```

**State files** (in `~/.ai-platform/`):

| File | Purpose |
|------|---------|
| `.active-port.json` | Current port, model, start time |
| `state/active-provider.json` | Live truth: provider, model, endpoint, why |
| `state/active-agent.json` | Coding certificate (profile, model, expiry, fit state) |
| `config/policies/provider-policy.json` | Your intent: preferred backend, cloud fallback rules |
| `config/models.json` | Model registry (sizes, capabilities, verdicts) |

**Key principle:** `provider-policy.json` = your *intent*. `active-provider.json` = *live truth*. They're separate so a crashed session can't look like a changed preference.

### 3. Backend Selection Logic

```
ai-start
  │
  ├─ First run? → Seed provider-policy.json → Check vLLM viability
  │                      │
  │                      ├─ NVIDIA GPU + Docker? → Ask: Ollama or vLLM?
  │                      │                              │
  │                      │                              ├─ vLLM → Health check → Ready
  │                      │                              └─ Fail → Fallback to Ollama
  │                      │
  │                      └─ No GPU/Docker → Default: Ollama
  │
  └─ Not first run? → Read provider-policy.json
                          │
                          ├─ Valid backend stored? → Launch it
                          └─ Invalid/missing → Same as first run
```

### 4. The Coding Certificate Flow

`ai-agent-start` doesn't just start a model. It proves it works.

```
ai-agent-start
  │
  ├─ Resolve profile (hardware-sized or explicit)
  │
  ├─ Acquire GGUF (Hugging Face → local cache, byte-verified)
  │
  ├─ Start llama-server (GPU layers = your free VRAM)
  │
  ├─ Verify template (llama-server /props → chat template check)
  │
  ├─ Run capability contract (Pi or opencode)
  │     │
  │     ├─ Configure harness (opencode.json / Pi config)
  │     ├─ Run live multi-turn test (bash/read/write loop)
  │     ├─ Verify structured tool calls at wire
  │     └─ Record: pass/fail + transport validity + fit state
  │
  ├─ Fit-state gate (ArtifactFit + TransportFit + HarnessFit)
  │
  └─ Publish active-agent.json (only on full pass)
        │
        ├─ Expires in 24h
        ├─ Bound to: profile, model digest, harness, endpoint
        └─ Required by ai-code, ai-claude-on, Pi
```

**Why this matters:** No more "works on my machine." The certificate proves *this* model on *this* hardware passes *this* contract.

---

## Supporting Services

### Memory Service (Port 12346)

```
┌────────────────────────────────────────────────────────────┐
│                    MEMORY SERVICE                           │
│  FastAPI + ChromaDB + LangGraph                             │
│  Port 12346                                                 │
├────────────────────────────────────────────────────────────┤
│  Routes:                                                    │
│  • GET  /health                    → Health + index freshness│
│  • POST /v1/memory/remember       → Store conversation       │
│  • POST /v1/memory/recall         → Retrieve relevant context│
│  • POST /v1/chat/completions      → Proxy with RAG injection │
│  • POST /coding/v1/chat/completions → Coding-aware RAG      │
├────────────────────────────────────────────────────────────┤
│  Data:                                                      │
│  • ~/.ai-platform/memory/chroma/        → Vector store       │
│  • ~/.ai-platform/memory/chroma-coding/ → Coding-specific    │
│  • LangGraph checkpointer (per-session) → Short-term memory  │
└────────────────────────────────────────────────────────────┘
```

**Routing:** `ai-memory-on` rewrites `active-provider.json` endpoint to memory service. `ai-memory-off` restores direct backend.

### Tool-Call Proxy (Port 12347)

```
Ollama /api/chat (native) → Grammar-constrained parser → OpenAI tool_calls format
```

Only for models that emit malformed tool calls. Not an agentic fix — just a translation layer. `ai-tool-proxy-start` / `ai-tool-proxy-stop`.

### Hermes Container

```
┌─────────────────────────────────────────────────────────────┐
│                    HERMES CONTAINER                          │
│  Docker, read-only career-ops mount, dropped capabilities   │
├─────────────────────────────────────────────────────────────┤
│  Mounts:                                                    │
│  • career-ops repo → /workspace (read-only)                 │
│  • output volume → /workspace/output                        │
│                                                             │
│  Env:                                                       │
│  • OLLAMA_HOST=host.docker.internal:12345                   │
│  • OPENAI_BASE_URL=http://host.docker.internal:12345/v1     │
│  • AIRLOCK_MODEL / AIRLOCK_PROFILE_ID (from certificate)    │
│                                                             │
│  Security:                                                  │
│  • cap_drop: ALL, cap_add: NET_BIND_SERVICE                 │
│  • no-new-privileges: true                                  │
│  • network: bridge with icc=false (no container-to-container)│
└─────────────────────────────────────────────────────────────┘
```

**Entry point:** `run-hermes.ps1` validates `active-agent.json` first. No cert = no launch.

### 3D Visualizer (Port 8347)

Standalone Three.js scene (`tools/3d-system-visualizer/index.html`). Reads audit logs → generates live scene → animates workflows. No build, no deps.

---

## Data Flow Examples

### Chat Request (`ai-start`)

```
User → ai-start → Start-AI.ps1
  → Single-instance check (kill rogues)
  → Backend selection (Ollama/vLLM)
  → Launch backend on 127.0.0.1:12345
  → Health check (/api/tags or /health)
  → Firewall rule (block inbound)
  → Write .active-port.json + active-provider.json
  → Audit log (SUCCESS)
  → Ready: http://127.0.0.1:12345/v1
```

### Coding Session (`ai-agent-start`)

```
User → ai-agent-start -DownloadConfirmed
  → Lock (bootstrap.lock)
  → Resolve profile (hardware-sized Unsloth quant)
  → Download GGUF (HuggingFace, byte-verified)
  → Start llama-server (dynamic port, --jinja, --flash-attn)
  → Verify template (/props → chat template check)
  → Memory service? Start embedding runtime if needed
  → Route through memory-service if healthy
  → Run Pi capability contract (live 3/3)
  → Fit-state gate (VRAM + Transport + Harness)
  → Publish active-agent.json (24h TTL)
  → Ready for ai-code / ai-claude-on / opencode
```

### Model Switch (`ai-switch`)

```
User → ai-switch qwen3-coder:30b
  → Check .active-port.json
  → Verify model exists in Ollama (/api/tags)
  → Update .active-port.json + active-provider.json
  → Invalidate active-agent.json (coding cert)
  → Audit log (ModelSwitch)
  → Done
```

---

## Configuration Files

| File | Purpose | User-Editable? |
|------|---------|----------------|
| `config/models.json` | Model registry (sizes, caps, verdicts) | Yes |
| `config/policies/provider-policy.json` | Routing, cloud fallback, preferred models | Yes |
| `config/policies/commit-policy.json` | Pre-commit block patterns | Yes |
| `config/*.template` | Copy to remove `.template` suffix, fill in | Yes (copy first) |
| `~/.ai-platform/state/active-provider.json` | Live runtime state | **No** (platform-managed) |
| `~/.ai-platform/state/active-agent.json` | Coding certificate | **No** (platform-managed) |
| `~/.ai-platform/.active-port.json` | Current port/model | **No** (platform-managed) |

---

## Security Boundaries

```
┌────────────────────────────────────────────────────────────────┐
│                    SECURITY BOUNDARIES                         │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  HOST OS (Windows)                                        │  │
│  │  ├─ Desktop, Documents, Downloads → NO ACCESS             │  │
│  │  ├─ Local code repos → NO ACCESS                          │  │
│  │  ├─ LAN / other containers → BLOCKED (firewall)           │  │
│  │  └─ ~/.ai-platform/ → FULL ACCESS (platform owns this)    │  │
│  └──────────────────────────────────────────────────────────┘  │
│                              │                                 │
│                              ▼                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  LOCAL BACKENDS (Ollama / llama-server / vLLM)            │  │
│  │  ├─ Bind: 127.0.0.1 ONLY (no 0.0.0.0)                    │  │
│  │  ├─ Firewall: Inbound 12345 BLOCKED                       │  │
│  │  ├─ Ollama: OLLAMA_NO_CLOUD=true, OLLAMA_CONTEXT=32768   │  │
│  │  └─ vLLM: --enable-auto-tool-choice                       │  │
│  └──────────────────────────────────────────────────────────┘  │
│                              │                                 │
│                              ▼                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  HERMES CONTAINER                                         │  │
│  │  ├─ Read-only: career-ops repo                            │  │
│  │  ├─ Volume: output only                                   │  │
│  │  ├─ Capabilities: DROP ALL, add NET_BIND_SERVICE          │  │
│  │  ├─ Network: bridge, icc=false (no container-to-container)│  │
│  │  └─ No host filesystem access                             │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## Extension Points

| Extension | How |
|-----------|-----|
| New harness | Add to `ValidateSet` in `Start-AgentSession.ps1`, implement `Invoke-<Harness>CapabilityContract.ps1` |
| New runtime | Add to `Resolve-SessionEndpointMode`, create `runtime-adapters/<name>.ps1` |
| New model | Add to `config/models.json` with `agenticLoopVerdict` |
| New policy | Edit `config/policies/provider-policy.json` |
| New agent CLI | Add setup section to README + config template in `config/` |

---

## Key Design Decisions (ADR References)

| Decision | ADR | Why |
|----------|-----|-----|
| Two doors (chat vs coding) | ADR-016 | Tool-calling ≠ chat; mixing breaks both |
| Certificate-based coding | ADR-013, ADR-016 | Prove on *this* hardware, not trust |
| Separate policy vs live state | ADR-011 | Stale runtime ≠ changed intent |
| Hardware-sized Unsloth | ADR-018, ADR-005 | VRAM-first, mmap fallback, no inheritance |
| Fail-closed cloud | ADR-006 | Missing secrets = no cloud, not silent fallback |
| Certificate TTL = 24h | ADR-012 | Hardware changes, certs expire |
| Llama-server single port | ADR-012 §6.2 | No proxy split like Ollama; one route |

---

## File Ownership Map

| Directory | Owner | Modified By |
|-----------|-------|-------------|
| `scripts/` | Platform core | PR review required |
| `config/` | Platform + User | User edits templates; platform manages state |
| `docs/` | Documentation | Anyone |
| `hermes-container/` | Hermes team | PR review |
| `memory-service/` | Memory team | PR review |
| `tools/3d-system-visualizer/` | Viz team | PR review |
| `src/extension.ts` | VS Code team | PR review |
| `~/.ai-platform/state/` | Platform only | **Never** user-edit |
| `~/.ai-platform/config/` | User | User edits copied templates |

---

*This document describes the architecture as implemented. If reality differs from this doc, reality wins — update the doc.*