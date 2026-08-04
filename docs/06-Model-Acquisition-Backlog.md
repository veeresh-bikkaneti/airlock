# Model Acquisition Backlog

## Problem
Today the platform assumes a model is already pulled and running in Ollama (see [`01-Local-AI-Platform-Blueprint.md`](01-Local-AI-Platform-Blueprint.md) routing rules and [`05-Provider-Fallback-Matrix.md`](05-Provider-Fallback-Matrix.md)). There is no logic to discover, choose, or fetch a model automatically. The user should never have to install Ollama, pull a model by name, or guess whether a model fits their hardware.

## Goal
Zero-touch setup: on first run (or when no suitable model is present), the platform checks Ollama's local/registry catalog and Hugging Face for available quantized models, picks the best one for the user's hardware, pulls it in the background, and starts it — all with verbose, human-readable logs.

## Stories

### 1. Detect available quantized models
**As a** user **I want** the platform to check Ollama and Hugging Face for quantized/compressed model builds **so that** I don't have to know model names or formats.
- Query Ollama's model library/registry for available tags.
- Query Hugging Face for GGUF (or other quantized) repos as a secondary source.
- Log each source checked and what was found.
- Priority: **P0**

### 2. Assess hardware capability
**As a** user **I want** the platform to detect my CPU/GPU/RAM/VRAM **so that** it only considers models likely to run acceptably.
- Detect total RAM, available VRAM (if a GPU is present), CPU core count.
- Map hardware profile to a max supportable model size/quantization level (e.g. Q4_K_M 7B needs ~6GB RAM).
- Log the detected hardware profile and the resulting size ceiling.
- Priority: **P0** (blocks story 3)

### 3. Prioritize the best model when multiple fit
**As a** user **I want** the platform to pick the single best-fitting model when several candidates qualify **so that** I get good quality without manual comparison.
- Rank qualifying candidates by a simple score: prefer the largest parameter count that still fits comfortably in detected RAM/VRAM (with headroom), tie-break by most recent/most-downloaded quantized build.
- Log the full candidate list, scores, and the winner with the reason it won.
- Priority: **P0**

### 2b. Provider fallback for acquisition
**As a** user **I want** Hugging Face used only when Ollama has no suitable match **so that** we don't add remote-download complexity unless needed.
- Extend the fallback matrix in [`05-Provider-Fallback-Matrix.md`](05-Provider-Fallback-Matrix.md) with an "acquisition" row: Ollama registry first, Hugging Face GGUF repo second.
- Priority: **P1**

### 4. Background pull and run, no manual steps
**As a** user **I want** the chosen model pulled and started automatically **so that** I never run `ollama pull` or `ollama run` myself.
- Trigger `ollama pull <model>` (or HF download + Ollama import) as a background/async operation so the app doesn't block.
- Auto-start the model once pulled, matching existing provider-selection flow in the blueprint.
- Handle already-pulled models as a no-op (skip re-download).
- Priority: **P0**

### 5. Verbose, human-readable logging throughout
**As a** user **I want** clear logs of every step **so that** I can see what's happening and trust the automation.
- Reuse the logging shape from [`01-Local-AI-Platform-Blueprint.md`](01-Local-AI-Platform-Blueprint.md#logging-model) (UTC timestamp, action, result, provider, model, message).
- Emit a log line for: sources checked, hardware profile detected, candidates found, candidate chosen and why, pull started/progress/finished, model started.
- Messages must be plain language, not just codes (e.g. "Your PC has 16GB RAM and no dedicated GPU — selected llama3.1:8b-q4_K_M as the best fit" rather than a bare model ID).
- Priority: **P0**

## Out of scope (for now)
- Multi-model concurrent serving.
- Cloud-hosted model fallback for acquisition (cloud providers remain chat-completion fallback only, per the existing fallback matrix).
- GPU driver installation or CUDA/ROCm setup.

## Open questions
- Where does the hardware-to-model-size mapping table live — hardcoded config or fetched/updated periodically?
- Should the user be able to override the auto-selected model, or is auto-selection final until they change a setting?
