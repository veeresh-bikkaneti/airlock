# Airlock Demo Video — Muse Execution Spec

**Target:** Cloud AI agent (Muse) with VM provisioning + screen recording capability
**Output:** 8-12 min MP4 demo video replacing stale brag video
**Tone:** Human, beginner-friendly, "watch me do it" — not marketing

---

## 1. VM PROVISIONING REQUIREMENTS

```yaml
vm_spec:
  provider: "aws | lambda | runpod | azure | gcp"  # any with NVIDIA GPU
  instance_type: "g5.xlarge | equivalent (1x A10G / RTX A5000, 24GB VRAM)"
  os: "Windows 11 Pro"  # Airlock is Windows-first
  storage: "100 GB SSD minimum"
  network: "Public IP + RDP/SSH access"
  gpu_driver: "NVIDIA 550+ (pre-installed or install script)"
  display: "Virtual display enabled (for OBS/ffmpeg capture)"

software_preinstall:
  - "Git for Windows"
  - "PowerShell 7.4+"
  - "Ollama (latest)"
  - "Docker Desktop (Windows containers + WSL2 backend)"
  - "OBS Studio (portable) OR ffmpeg + virtual display"
  - "VS Code (optional, for architecture diagram viewing)"
  - "Chrome/Edge (for web chat demo)"

# If Linux VM only (no Windows):
#   - Ubuntu 22.04 + NVIDIA drivers + Docker + pwsh 7.4+
#   - Note: Airlock scripts are .ps1 — needs pwsh, some paths differ
```

**Muse Action:** Provision VM, install software, verify `nvidia-smi` shows GPU, verify `pwsh --version` ≥ 7.4.

---

## 2. RECORDING SETUP

```yaml
recording:
  tool: "OBS Studio (preferred) OR ffmpeg with xvfb"
  canvas: "1920x1080 @ 30fps"
  audio: "Microphone input → narration track"
  sources:
    - "Full desktop capture (PowerShell + browser + VS Code)"
    - "Optional: webcam corner (if Muse has avatar)"
  output: "demo-raw.mkv (lossless) → demo-final.mp4 (H.264, CRF 18)"
  hotkeys:
    start_recording: "F9"
    stop_recording: "F10"
    pause: "F11"
```

**Muse Action:** Configure OBS/ffmpeg, test 10-second capture, verify audio + video sync.

---

## 3. DEMO SCRIPT — SEQUENCE OF SHOTS

Each section = one continuous take (pause recording between sections if needed).

### SHOT 0: COLD OPEN (15 sec)
**Action:** Fresh VM desktop. No Airlock installed.
**Narration:** *"This is a clean Windows 11 VM. No Ollama, no Python, no Git. Just Windows. Let's see what Airlock does from zero."*
**Visual:** Show empty Start menu, `pwsh` not in PATH, `ollama` not found.

---

### SHOT 1: BOOTSTRAP INSTALL (60 sec)
**Commands:**
```powershell
# Run in Admin PowerShell
irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex
```

**Narration Cues (speak WHILE it runs):**
- *"Downloads the repo to ~/.airlock-src"*
- *"Runs setup.ps1 — copies all scripts and configs to ~/.ai-platform"*
- *"Installs PowerShell 7, Git, Ollama via winget if missing"*
- *"Hooks profile-helpers.ps1 into my PowerShell $PROFILE so ai-* commands work everywhere"*
- *"Wait for 'Setup complete'..."*

**Visual:** Show terminal output scrolling. When done, show `ai-start --help`, `ai-agent-start --help`, `ai-setup --help` all work.

---

### SHOT 2: INTERACTIVE SETUP (45 sec)
**Commands:**
```powershell
ai-setup
# Menu appears → type: 1,2,5  (Pi, opencode, memory-service)
# Confirm: y
```

**Narration:**
- *"ai-setup is the one-time configurator. Multi-select menu — pick what you want."*
- *"1 = Pi (primary coding agent, runs live 3/3 contract)"*
- *"2 = opencode (file-based agent, auto-configures to Airlock endpoint)"*
- *"5 = Memory Service (RAG + session persistence, FastAPI + Chroma + LangGraph on port 12346)"*
- *"It writes config files: ~/.pi/agent/models.json, ~/.opencode/opencode.json, starts memory-service"*

**Visual:** Show menu, selection, output. Then `ls ~/.pi/agent/ ~/.opencode/` to prove files exist.

---

### SHOT 3: CHAT DOOR — ai-start (60 sec)
**Commands:**
```powershell
ai-start
```

**Narration (narrate the output as it appears):**
- *"Single-instance enforcement — kills any rogue Ollama on port 12345"*
- *"Backend selection: detected NVIDIA GPU + Docker. Asks: Ollama or vLLM?"* → **Choose O (Ollama)**
- *"Resource check: shows my free RAM and VRAM"*
- *"Auto-picks model that fits: devstral-small-2:24b for my 24GB VRAM"*
- *"Pulls model in background — startup continues without waiting"*
- *"Firewall rule: blocks inbound 12345 — no external access"*
- *"Sets env vars: OLLAMA_HOST, OPENAI_BASE_URL, OLLAMA_NO_CLOUD=true"*

**Visual:** Full terminal output. Then run:
```powershell
ai-health
```
**Narration:** *"Health check — processes, API, firewall, RAM, VRAM, coding cert status. All green."*

---

### SHOT 4: TEST CHAT DOOR (30 sec)
**Commands:**
```powershell
# Option A: curl
curl http://127.0.0.1:12345/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{"model":"devstral-small-2:24b","messages":[{"role":"user","content":"Hello, world!"}]}'

# Option B: ai-code (opens aider in chat mode)
ai-code
# Type: "write a haiku about local AI" → show it works
# Exit aider: Ctrl+C
```

**Narration:** *"Chat door is live. OpenAI-compatible endpoint at 127.0.0.1:12345/v1. Any tool that speaks OpenAI works. This is the NON-agentic door — just chat."*

---

### SHOT 5: CODING DOOR — ai-agent-start (90 sec)
**Commands:**
```powershell
ai-agent-start -DownloadConfirmed
```

**Narration (LIVE as it runs — this is the money shot):**
- *"Lock acquired — only one coding session at a time"*
- *"Resolves profile: hardware-sized Unsloth Dynamic 3.0 quant. For my 24GB VRAM → UD-Q3_K_XL"*
- *"Downloads GGUF from Hugging Face — one-time, ~15GB, byte-verified"*
- *"Starts llama-server on dynamic port with GPU layers = free VRAM, Jinja template, flash-attn"*
- *"Verifies chat template supports tool calls via /props"*
- *"Memory service healthy? Yes — routes through it for RAG"*
- *"Runs LIVE Pi 3/3 capability contract: real multi-turn coding test (bash/read/write loop)"*
- *"Fit-state gate: ArtifactFit (model digest matches), TransportFit (structured tool calls at wire), HarnessFit (Pi 3/3 PASS)"*
- *"ONLY on full pass: publishes active-agent.json (24h TTL, bound to profile+model+harness+endpoint)"*

**Visual:** Full terminal output. Wait for completion. Then:
```powershell
ai-health
```
**Show:** Coding cert now shows "valid until [tomorrow]"

---

### SHOT 6: PROVE CODING DOOR WORKS (60 sec)
**Commands (run each, show result):**
```powershell
# Aider with coding endpoint
ai-code
# In aider: "Create a Python script that fetches a URL and saves it to a file"
# Show it writes file, runs it, works
# Exit

# opencode (configured by ai-setup)
ai-opencode
# In opencode: "add a README to this folder"
# Show file-based workflow
# Exit

# Claude Code (session-scoped, safe)
ai-claude-on
claude "write a hello world in rust"
ai-claude-off
# Show it used local model, no settings.json pollution
```

**Narration:** *"Three harnesses, same proven endpoint. ai-code = aider (pair programming). ai-opencode = file-based agent. ai-claude-on = session env vars only — never touches your real Claude Code config."*

---

### SHOT 7: MEMORY SERVICE — RECALL DEMO (45 sec)
**Commands:**
```powershell
ai-memory-on
# Chat via curl or ai-code:
curl http://127.0.0.1:12345/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{"model":"devstral-small-2:24b","messages":[{"role":"user","content":"My favorite color is teal. Remember this."}]}'
# Wait, then:
curl http://127.0.0.1:12345/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{"model":"devstral-small-2:24b","messages":[{"role":"user","content":"What's my favorite color?"}]}'
ai-memory-off
```

**Narration:** *"ai-memory-on rewrites the endpoint to route through memory service (port 12346). It injects relevant context via RAG. Watch — it remembers 'teal' across requests. ai-memory-off restores direct backend."*

---

### SHOT 8: ARCHITECTURE WALKTHROUGH (60 sec)
**Actions:**
1. Open `README.md` in VS Code (or browser GitHub)
2. Scroll to architecture diagram (Mermaid renders in GitHub/VS Code)
3. Open `docs/ARCHITECTURE.md` — show:
   - 5-layer stack diagram
   - State machine
   - Backend selection flow
   - Coding certificate flow
   - Security boundaries
4. Open `docs/VISION.md` — show vision→mission→goals flow
5. Open `docs/07-Quickstart-Playbook.md` — show quick flow diagram

**Narration:** *"Every diagram is Mermaid — renders in GitHub, VS Code, no build step. The architecture doc explains the two doors, state machine, certificate flow, security boundaries. Vision doc is the north star. Quickstart is the playbook."*

---

### SHOT 9: MODEL SWITCH + CLEANUP (30 sec)
**Commands:**
```powershell
# Switch model mid-session
ai-switch qwen3-coder:30b
# Show active-provider.json updated
# Show coding cert INVALIDATED (by design)

# Stop everything
ai-stop
# Show processes gone, firewall rule removed, state cleared
```

**Narration:** *"Switching models kills the coding cert — honest about capabilities. ai-stop cleans everything: processes, firewall, state files. Next session starts fresh."*

---

### SHOT 10: OUTRO (15 sec)
**Visual:** Terminal showing `ai-uninstall -WhatIf` then GitHub repo page.
**Narration:** *"That's Airlock. One door open at a time. It tells you the truth, even about itself. github.com/veeresh-bikkaneti/airlock"*

---

## 4. POST-PROCESSING REQUIREMENTS

```yaml
editing:
  - "Trim dead air (waiting for downloads)"
  - "Add section titles as lower-thirds: 'Bootstrap', 'Chat Door', 'Coding Door', etc."
  - "Zoom/pan on terminal output for key lines (model size, VRAM gate, cert published)"
  - "Keep narration natural — don't edit out 'um's, breathes"
  - "No background music — or very subtle ambient"
  - "End slate: Airlock logo + GitHub URL + 'One door open at a time.'"

delivery:
  format: "MP4, H.264, 1920x1080, 30fps, CRF 18"
  filename: "airlock-demo-YYYY-MM-DD.mp4"
  upload: "Push to repo: brag-output-YYYY-MM-DD-HHMMSS/ composition + video"
```

---

## 5. MUSE EXECUTION CHECKLIST

```markdown
- [ ] Provision VM per spec
- [ ] Install all software_preinstall items
- [ ] Configure OBS/ffmpeg recording
- [ ] Test 10-sec capture + audio
- [ ] Execute SHOT 0 → SHOT 10 in sequence
- [ ] Pause recording between shots if needed
- [ ] Verify each shot captured cleanly
- [ ] Post-process per editing spec
- [ ] Render final MP4
- [ ] Push to airlock repo under new brag-output-*/ folder
- [ ] Update composition/index.html if needed
- [ ] Create PR with video + updated composition
```

---

## 6. FAILURE HANDLING

| Failure | Muse Action |
|---------|-------------|
| `ai-start` picks wrong model | Narrate: "It picked X but I have Y VRAM — let me switch with ai-switch" |
| `ai-agent-start` fails VRAM gate | Narrate: "This is the VRAM gate — it's honest. My GPU doesn't have enough free VRAM for this quant. Let me use a smaller model or stick to chat door." |
| Pi contract fails | Narrate: "Contract failed — this is the point. It tells you exactly which gate failed. No silent broken tool calls." |
| Memory service unhealthy | Narrate: "Memory service not healthy — falls back to direct backend. That's by design." |
| Docker/Hermes fails | Skip — user said "I'll test Hermes via Docker later" |

---

## 7. KEY MESSAGES TO LAND (Human Tone)

> *"Airlock doesn't pretend. If your hardware can't run agentic coding, it says so. If a model fails the live contract, you know before you waste time."*
>
> *"Two doors: chat (easy, broad models) and coding (proven, hardware-sized). Mixing them breaks both."*
>
> *"The certificate isn't a badge — it's a receipt. This model, this hardware, this harness, this moment. 24 hours later, re-prove it."*
>
> *"Complexity lives in the platform. You type `ai-start`. That's it."*

---

**End of Spec.** Muse should execute top-to-bottom, narrating continuously, capturing everything. The result replaces the stale brag video with an honest, technical, beginner-friendly walkthrough.