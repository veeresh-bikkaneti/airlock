# Airlock Architecture

*How the pieces fit together — in plain English.*

---

## The Big Picture

```mermaid
flowchart TB
    subgraph WINDOWS["YOUR WINDOWS PC"]
        A1["ai-start\n(Chat Door)"]
        A2["ai-agent-start\n(Coding Door)"]
        A3["ai-setup\n(Interactive)"]
        
        PH["profile-helpers.ps1\n(All ai-* commands,\nstate management)"]
        
        OLLAMA["Ollama\n(Chat)\nPort 12345"]
        LLAMASRV["llama-server\n(Coding)\nDynamic Port"]
        VLLM["vLLM (Docker)\n(Optional)\nPort 12345"]
        
        ENDPOINT["OpenAI-Compatible Endpoint\nhttp://127.0.0.1:12345/v1\n/v1/responses + /v1/messages"]
        
        AIDER["aider (ai-code)"]
        CLAUDE["Claude Code\n(ai-claude-on/off)"]
        OPENCODE["opencode\n(ai-opencode)"]
        
        SUPPORT["Supporting Services (Optional)"]
        MEM["Memory Service\nFastAPI + Chroma + LangGraph\n:12346"]
        PROXY["Tool-Call Proxy\nGrammar-constrained\n:12347"]
        HERMES["Hermes Container\nCareer-ops sandbox"]
        VIZ["3D Visualizer\nThree.js\n:8347"]
    end
    
    A1 --> PH
    A2 --> PH
    A3 --> PH
    
    PH --> OLLAMA
    PH --> LLAMASRV
    PH --> VLLM
    
    OLLAMA --> ENDPOINT
    LLAMASRV --> ENDPOINT
    VLLM --> ENDPOINT
    
    ENDPOINT --> AIDER
    ENDPOINT --> CLAUDE
    ENDPOINT --> OPENCODE
    
    PH --> SUPPORT
    SUPPORT --> MEM
    SUPPORT --> PROXY
    SUPPORT --> HERMES
    SUPPORT --> VIZ
    
    classDef door fill:#1a1f1d,stroke:#4fc3b8,stroke-width:2px,color:#dcd8c9
    classDef core fill:#0c100e,stroke:#39433c,stroke-width:1.5px,color:#dcd8c9
    classDef endpoint fill:#1a1f1d,stroke:#e8a23c,stroke-width:2px,color:#dcd8c9
    classDef agent fill:#1a1f1d,stroke:#4fc3b8,stroke-width:1.5px,color:#dcd8c9
    classDef support fill:#0c100e,stroke:#39433c,stroke-width:1px,stroke-dasharray: 5 5,color:#8a9089
    
    class A1,A2,A3 door
    class PH,OLLAMA,LLAMASRV,VLLM core
    class ENDPOINT endpoint
    class AIDER,CLAUDE,OPENCODE agent
    class SUPPORT,MEM,PROXY,HERMES,VIZ support
```

---

## Core Components

### 1. The Two Doors

```mermaid
flowchart LR
    subgraph CHAT["Chat Door"]
        AI_START["ai-start"]
        OLLAMA_C["Ollama / vLLM\nPort 12345"]
        MODEL_CHAT["Auto-picked model\nfor your VRAM"]
    end
    
    subgraph CODING["Coding Door"]
        AI_AGENT["ai-agent-start / ai-opencode"]
        UNSLOTH["Unsloth Dynamic 3.0\nHardware-sized quant"]
        GGUF["GGUF from HuggingFace\nByte-verified"]
        LLAMA_SRV["llama-server\nDynamic port"]
        CONTRACT["Live Pi 3/3 Contract\nMulti-turn coding test"]
        CERT["active-agent.json\n24h TTL"]
    end
    
    AI_START --> OLLAMA_C --> MODEL_CHAT
    AI_AGENT --> UNSLOTH --> GGUF --> LLAMA_SRV --> CONTRACT --> CERT
    
    style CHAT fill:#0c100e,stroke:#4fc3b8,stroke-width:2px
    style CODING fill:#0c100e,stroke:#e8a23c,stroke-width:2px
```

| Door | Entry Point | What It Does |
|------|-------------|--------------|
| **Chat** | `ai-start` | Starts Ollama or vLLM on port 12345. Single-instance, firewall-guarded, audit-logged. Auto-picks model for your VRAM. |
| **Coding** | `ai-agent-start` / `ai-opencode` | Sizes Unsloth Dynamic 3.0 to *your* free VRAM → downloads GGUF → starts llama-server → runs live Pi 3/3 contract → publishes certificate. |

**Why two doors?** Chat doesn't need tool-calling. Coding does. Mixing them means broken tool calls in chat or oversized models for coding. Two doors = honest capabilities.

### 2. The State Machine

```mermaid
stateDiagram-v2
    [*] --> START
    START --> CHECK_LOCK: Single-instance enforcement
    CHECK_LOCK --> SELECT_BACKEND: Backend selection logic
    SELECT_BACKEND --> VERIFY_HEALTH: Health check endpoint
    VERIFY_HEALTH --> PUBLISH_STATE: Write state files
    PUBLISH_STATE --> READY: Platform operational
    
    READY --> STOP: ai-stop / crash
    STOP --> CLEAR_STATE: Remove locks, state files
    CLEAR_STATE --> [*]
    
    note right of SELECT_BACKEND
        First run: seed policy, check vLLM viability
        Returning: read provider-policy.json
    end note
    
    note right of VERIFY_HEALTH
        /api/tags (Ollama) or /health (vLLM)
        Firewall rule: block inbound 12345
    end note
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

```mermaid
flowchart TD
    AI_START["ai-start"] --> FIRST_RUN{"First run?"}
    
    FIRST_RUN -- Yes --> SEED_POLICY["Seed provider-policy.json"]
    SEED_POLICY --> CHECK_VLLM{"NVIDIA GPU\n+ Docker?"}
    
    CHECK_VLLM -- Yes --> ASK_BACKEND["Ask: Ollama or vLLM?"]
    ASK_BACKEND --> VLLM_CHOICE{"vLLM chosen?"}
    VLLM_CHOICE -- Yes --> VLLM_HEALTH["Health check vLLM"]
    VLLM_HEALTH -- Pass --> READY_VLLM["Ready: vLLM"]
    VLLM_HEALTH -- Fail --> FALLBACK_OLLAMA["Fallback to Ollama"]
    VLLM_CHOICE -- No --> READY_OLLAMA["Ready: Ollama"]
    
    CHECK_VLLM -- No --> READY_OLLAMA
    
    FIRST_RUN -- No --> READ_POLICY["Read provider-policy.json"]
    READ_POLICY --> VALID_BACKEND{"Valid backend\nstored?"}
    VALID_BACKEND -- Yes --> LAUNCH["Launch stored backend"]
    VALID_BACKEND -- No --> SEED_POLICY
    
    READY_VLLM --> READY["Platform Ready"]
    READY_OLLAMA --> READY
    FALLBACK_OLLAMA --> READY
    LAUNCH --> READY
    
    style AI_START fill:#1a1f1d,stroke:#4fc3b8
    style READY fill:#0c100e,stroke:#4fc3b8
```

### 4. The Coding Certificate Flow

```mermaid
flowchart TD
    AI_AGENT_START["ai-agent-start\n-DownloadConfirmed"]
    
    AI_AGENT_START --> LOCK["Lock (bootstrap.lock)"]
    LOCK --> RESOLVE_PROFILE["Resolve profile\nHardware-sized Unsloth quant"]
    RESOLVE_PROFILE --> DOWNLOAD_GGUF["Download GGUF\nHuggingFace → local cache\nByte-verified"]
    DOWNLOAD_GGUF --> START_LLAMA["Start llama-server\nGPU layers = free VRAM\n--jinja, --flash-attn"]
    START_LLAMA --> VERIFY_TEMPLATE["Verify template\nllama-server /props\nChat template check"]
    VERIFY_TEMPLATE --> MEMORY_CHECK{"Memory service\nhealthy?"}
    
    MEMORY_CHECK -- Yes --> START_EMBEDDING["Start embedding runtime"]
    START_EMBEDDING --> ROUTE_MEMORY["Route through\nmemory-service"]
    ROUTE_MEMORY --> RUN_CONTRACT
    MEMORY_CHECK -- No --> RUN_CONTRACT["Run Pi capability contract\nLive 3/3 multi-turn test"]
    
    RUN_CONTRACT --> FIT_GATE["Fit-state gate"]
    FIT_GATE --> ARTIFACT_FIT["ArtifactFit: model digest\nmatches downloaded GGUF"]
    FIT_GATE --> TRANSPORT_FIT["TransportFit: structured\ntool calls at wire"]
    FIT_GATE --> HARNESS_FIT["HarnessFit: Pi 3/3 PASS"]
    
    ARTIFACT_FIT --> ALL_PASS{"All gates\npass?"}
    TRANSPORT_FIT --> ALL_PASS
    HARNESS_FIT --> ALL_PASS
    
    ALL_PASS -- Yes --> PUBLISH_CERT["Publish active-agent.json\n24h TTL\nBound to: profile, model,\nharness, endpoint"]
    ALL_PASS -- No --> FAIL["FAIL: exact gate\nlogged + audit trail"]
    
    PUBLISH_CERT --> READY_CODING["Ready for:\nai-code / ai-claude-on /\nopencode / Pi"]
    
    style AI_AGENT_START fill:#1a1f1d,stroke:#e8a23c
    style PUBLISH_CERT fill:#0c100e,stroke:#4fc3b8
    style FAIL fill:#1a1f1d,stroke:#e0665a
```

**Why this matters:** No more "works on my machine." The certificate proves *this* model on *this* hardware passes *this* contract.

---

## Supporting Services

### Memory Service (Port 12346)

```mermaid
flowchart TB
    subgraph MEM_SVC["Memory Service\nFastAPI + ChromaDB + LangGraph\nPort 12346"]
        ROUTES["Routes:"]
        HEALTH["GET /health\n→ Health + index freshness"]
        REMEMBER["POST /v1/memory/remember\n→ Store conversation"]
        RECALL["POST /v1/memory/recall\n→ Retrieve relevant context"]
        CHAT["POST /v1/chat/completions\n→ Proxy with RAG injection"]
        CODING["POST /coding/v1/chat/completions\n→ Coding-aware RAG"]
        
        DATA["Data Stores:"]
        CHROMA["~/.ai-platform/memory/chroma/\n→ Vector store"]
        CHROMA_CODING["~/.ai-platform/memory/chroma-coding/\n→ Coding-specific"]
        LANGGRAPH["LangGraph checkpointer\n(per-session)\n→ Short-term memory"]
    end
    
    ROUTES --> HEALTH
    ROUTES --> REMEMBER
    ROUTES --> RECALL
    ROUTES --> CHAT
    ROUTES --> CODING
    
    DATA --> CHROMA
    DATA --> CHROMA_CODING
    DATA --> LANGGRAPH
```

**Routing:** `ai-memory-on` rewrites `active-provider.json` endpoint to memory service. `ai-memory-off` restores direct backend.

### Tool-Call Proxy (Port 12347)

```mermaid
flowchart LR
    OLLAMA_NATIVE["Ollama /api/chat\n(native format)"] --> GRAMMAR["Grammar-constrained\nparser"]
    GRAMMAR --> OPENAI_FORMAT["OpenAI tool_calls\nformat"]
    
    style OLLAMA_NATIVE fill:#0c100e,stroke:#39433c
    style GRAMMAR fill:#1a1f1d,stroke:#e8a23c
    style OPENAI_FORMAT fill:#0c100e,stroke:#4fc3b8
```

Only for models that emit malformed tool calls. Not an agentic fix — just a translation layer. `ai-tool-proxy-start` / `ai-tool-proxy-stop`.

### Hermes Container

```mermaid
flowchart TB
    subgraph HERMES["Hermes Container\nDocker, read-only mount, dropped capabilities"]
        MOUNTS["Mounts:"]
        RO_MOUNT["career-ops repo → /workspace\n(read-only)"]
        OUT_VOL["output volume → /workspace/output"]
        
        ENVS["Environment:"]
        OLLAMA_HOST["OLLAMA_HOST=host.docker.internal:12345"]
        OPENAI_URL["OPENAI_BASE_URL=http://host.docker.internal:12345/v1"]
        AIRLOCK_VARS["AIRLOCK_MODEL /\nAIRLOCK_PROFILE_ID\n(from certificate)"]
        
        SEC["Security:"]
        CAP_DROP["cap_drop: ALL\ncap_add: NET_BIND_SERVICE"]
        NO_NEW_PRIV["no-new-privileges: true"]
        NETWORK["network: bridge\nicc=false (no container-to-container)"]
    end
    
    MOUNTS --> RO_MOUNT
    MOUNTS --> OUT_VOL
    ENVS --> OLLAMA_HOST
    ENVS --> OPENAI_URL
    ENVS --> AIRLOCK_VARS
    SEC --> CAP_DROP
    SEC --> NO_NEW_PRIV
    SEC --> NETWORK
```

**Entry point:** `run-hermes.ps1` validates `active-agent.json` first. No cert = no launch.

### 3D Visualizer (Port 8347)

Standalone Three.js scene (`tools/3d-system-visualizer/index.html`). Reads audit logs → generates live scene → animates workflows. No build, no deps.

---

## Data Flow Examples

### Chat Request (`ai-start`)

```mermaid
sequenceDiagram
    participant User
    participant AI_START as ai-start
    participant START_AI as Start-AI.ps1
    participant BACKEND as Ollama/vLLM
    participant STATE as State Files
    participant AUDIT as Audit Log
    
    User->>AI_START: ai-start
    AI_START->>START_AI: Invoke
    START_AI->>START_AI: Single-instance check (kill rogues)
    START_AI->>START_AI: Backend selection (Ollama/vLLM)
    START_AI->>BACKEND: Launch on 127.0.0.1:12345
    BACKEND-->>START_AI: Health check (/api/tags or /health)
    START_AI->>START_AI: Firewall rule (block inbound 12345)
    START_AI->>STATE: Write .active-port.json + active-provider.json
    START_AI->>AUDIT: Log SUCCESS
    START_AI-->>User: Ready: http://127.0.0.1:12345/v1
```

### Coding Session (`ai-agent-start`)

```mermaid
sequenceDiagram
    participant User
    participant AI_AGENT as ai-agent-start
    participant PROFILE as Profile Resolution
    participant HF as HuggingFace
    participant LLAMA as llama-server
    participant TEMPLATE as Template Check
    participant MEMORY as Memory Service
    participant CONTRACT as Pi Contract
    participant FIT as Fit-State Gate
    participant CERT as active-agent.json
    
    User->>AI_AGENT: ai-agent-start -DownloadConfirmed
    AI_AGENT->>AI_AGENT: Lock (bootstrap.lock)
    AI_AGENT->>PROFILE: Resolve profile (hardware-sized)
    PROFILE-->>AI_AGENT: Unsloth quant (e.g., UD-Q3_K_XL)
    AI_AGENT->>HF: Download GGUF (byte-verified)
    HF-->>AI_AGENT: GGUF cached locally
    AI_AGENT->>LLAMA: Start llama-server (dynamic port)
    LLAMA-->>AI_AGENT: Ready
    AI_AGENT->>TEMPLATE: Verify /props chat template
    TEMPLATE-->>AI_AGENT: Template valid
    
    alt Memory service healthy
        AI_AGENT->>MEMORY: Start embedding runtime
        MEMORY-->>AI_AGENT: Healthy
        AI_AGENT->>MEMORY: Route through memory-service
    end
    
    AI_AGENT->>CONTRACT: Run live Pi 3/3 contract
    CONTRACT-->>AI_AGENT: Pass/Fail + transport validity
    AI_AGENT->>FIT: Fit-state gate (VRAM + Transport + Harness)
    FIT-->>AI_AGENT: All gates pass
    AI_AGENT->>CERT: Publish active-agent.json (24h TTL)
    CERT-->>User: Ready for ai-code / ai-claude-on / opencode
```

### Model Switch (`ai-switch`)

```mermaid
sequenceDiagram
    participant User
    participant AI_SWITCH as ai-switch
    participant PORT as .active-port.json
    participant OLLAMA as Ollama API
    participant STATE as State Files
    participant AUDIT as Audit Log
    
    User->>AI_SWITCH: ai-switch qwen3-coder:30b
    AI_SWITCH->>PORT: Check current port/model
    AI_SWITCH->>OLLAMA: Verify model exists (/api/tags)
    OLLAMA-->>AI_SWITCH: Model available
    AI_SWITCH->>STATE: Update .active-port.json + active-provider.json
    AI_SWITCH->>STATE: Invalidate active-agent.json (coding cert)
    AI_SWITCH->>AUDIT: Log ModelSwitch
    AI_SWITCH-->>User: Done
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

```mermaid
flowchart TB
    subgraph HOST["HOST OS (Windows)"]
        NO_ACCESS["Desktop, Documents, Downloads → NO ACCESS"]
        NO_REPOS["Local code repos → NO ACCESS"]
        BLOCKED_LAN["LAN / other containers → BLOCKED (firewall)"]
        FULL_AI["~/.ai-platform/ → FULL ACCESS (platform owns this)"]
    end
    
    subgraph BACKENDS["LOCAL BACKENDS\n(Ollama / llama-server / vLLM)"]
        BIND["Bind: 127.0.0.1 ONLY (no 0.0.0.0)"]
        FIREWALL["Firewall: Inbound 12345 BLOCKED"]
        OLLAMA_CFG["Ollama: OLLAMA_NO_CLOUD=true\nOLLAMA_CONTEXT=32768"]
        VLLM_CFG["vLLM: --enable-auto-tool-choice"]
    end
    
    subgraph HERMES_CTN["HERMES CONTAINER"]
        RO_REPO["Read-only: career-ops repo"]
        OUT_ONLY["Volume: output only"]
        CAPS["Capabilities: DROP ALL\nadd NET_BIND_SERVICE"]
        NO_PRIV["no-new-privileges: true"]
        NET_ISO["Network: bridge, icc=false\n(no container-to-container)"]
        NO_HOST_FS["No host filesystem access"]
    end
    
    HOST --> BACKENDS
    BACKENDS --> HERMES_CTN
    
    style HOST fill:#0c100e,stroke:#39433c,stroke-width:2px
    style BACKENDS fill:#0c100e,stroke:#39433c,stroke-width:2px
    style HERMES_CTN fill:#1a1f1d,stroke:#e8a23c,stroke-width:2px
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