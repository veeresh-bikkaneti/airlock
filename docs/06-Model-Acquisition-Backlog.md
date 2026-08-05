# Model Acquisition Backlog

## Problem
Today the platform assumes a model is already pulled and running in Ollama (see [`01-Local-AI-Platform-Blueprint.md`](01-Local-AI-Platform-Blueprint.md) routing rules and [`05-Provider-Fallback-Matrix.md`](05-Provider-Fallback-Matrix.md)). There is no logic to discover, choose, or fetch a model automatically. The user should never have to install Ollama, pull a model by name, or guess whether a model fits their hardware.

## Goal
Zero-touch setup: on first run (or when no suitable model is present), the platform checks Ollama's local/registry catalog and Hugging Face for available quantized models, picks the best one for the user's hardware, pulls it in the background, and starts it — all with verbose, human-readable logs.

## Stories

### 1. Detect available quantized models — **Status: Done**
**As a** user **I want** the platform to check Ollama and Hugging Face for quantized/compressed model builds **so that** I don't have to know model names or formats.
- Query Ollama's model library/registry for available tags.
- Query Hugging Face for GGUF (or other quantized) repos as a secondary source.
- Log each source checked and what was found.
- Priority: **P0**
- Implemented: `Get-ModelDiscoverySources` (`scripts/Get-ModelAcquisition.ps1:5-57`) checks the curated `config/models.json` list first and queries the Hugging Face GGUF search API as a secondary source, logging both. HF acquisition is now wired: `Get-HuggingFaceGGUFCandidate` queries individual repos for file details and filters by size. Ollama has no public "list all pullable tags" API, so the "registry" side is a maintained curated list rather than a live query — acceptable per [`05-Provider-Fallback-Matrix.md`](05-Provider-Fallback-Matrix.md#model-acquisition-fallback).

### 2. Assess hardware capability — **Status: Done**
**As a** user **I want** the platform to detect my CPU/GPU/RAM/VRAM **so that** it only considers models likely to run acceptably.
- Detect total RAM, available VRAM (if a GPU is present), CPU core count.
- Map hardware profile to a max supportable model size/quantization level (e.g. Q4_K_M 7B needs ~6GB RAM).
- Log the detected hardware profile and the resulting size ceiling.
- Priority: **P0** (blocks story 3)
- Implemented: `Test-ResourceAvailability` (`scripts/Get-ModelAcquisition.ps1:59`) reads RAM via `Win32_OperatingSystem`, VRAM via `nvidia-smi`, cores via `Win32_ComputerSystem`.
- **Fixed:** Model sizing now uses system RAM (FreeMemGB) as the ceiling regardless of GPU presence. GPU info is computed and logged as informational/speed context only. Rationale: Ollama automatically offloads model layers that don't fit in VRAM to CPU/RAM, so GPU only affects inference speed, not whether a model can run. Sizing logic extracted to `Get-ModelSizingCeilingGB` (`scripts/Get-ModelAcquisition.ps1:88`) for testability. Regression test confirms 4GB GPU + 32GB RAM box gets sized to 32GB, not 4GB. See ADR-001 decision point 3.

### 3. Prioritize the best model when multiple fit — **Status: Done**
**As a** user **I want** the platform to pick the single best-fitting model when several candidates qualify **so that** I get good quality without manual comparison.
- Rank qualifying candidates by a simple score: prefer the largest parameter count that still fits comfortably in detected RAM/VRAM (with headroom), tie-break by most recent/most-downloaded quantized build.
- Log the full candidate list, scores, and the winner with the reason it won.
- Priority: **P0**
- Implemented: `scripts/Start-AI.ps1:272-309` scores each `fallbackOrder` candidate against `$availableGB` with a 20% headroom multiplier, picks the largest that fits, falls back to the smallest on no-fit. Verified by `scripts/Test-ModelSelection.ps1` (4/4 cases pass as of this check).

### 2b. Provider fallback for acquisition — **Status: Done**
**As a** user **I want** Hugging Face used only when Ollama has no suitable match **so that** we don't add remote-download complexity unless needed.
- Extend the fallback matrix in [`05-Provider-Fallback-Matrix.md`](05-Provider-Fallback-Matrix.md) with an "acquisition" row: Ollama registry first, Hugging Face GGUF repo second.
- Priority: **P1**
- Implemented: [`05-Provider-Fallback-Matrix.md`](05-Provider-Fallback-Matrix.md#model-acquisition-fallback) has the row, and `Get-ModelDiscoverySources` gates the HF query behind the curated list having no fit, matching the doc.

### 4. Background pull and run, no manual steps — **Status: Done**
**As a** user **I want** the chosen model pulled and started automatically **so that** I never run `ollama pull` or `ollama run` myself.
- Trigger `ollama pull <model>` (or HF download + Ollama import) as a background/async operation so the app doesn't block.
- Auto-start the model once pulled, matching existing provider-selection flow in the blueprint.
- Handle already-pulled models as a no-op (skip re-download).
- Priority: **P0**
- Implemented: `scripts/Get-ModelAcquisition.ps1:350-437` runs `ollama pull` in a background `Start-Job` for curated models, or launches `Start-HuggingFaceImport` for HF-sourced models. Both warm the model with a no-prompt `/api/generate` call and skip already-available models. `Start-ModelAcquisitionPull` (lines 343-437) detects HF models by name prefix and skips registry pull for them.

### 4b. Wire up Hugging Face acquisition — **Status: Done**
**As a** user **I want** a model actually downloaded from Hugging Face when nothing in the curated Ollama list fits **so that** the "check HF" story pays off instead of just logging a source that never supplies a model.
- Download the winning HF GGUF repo's file and `ollama create` an import from it, reusing the same background-job + audit-log pattern as story 4.
- Priority: **P1**
- Implemented: `Get-HuggingFaceGGUFCandidate` (`scripts/Get-ModelAcquisition.ps1:88-151`) queries HF's `/api/models` endpoint for GGUF files, gets sizes via `Content-Length` HEAD requests when needed, and filters by 20% headroom. `Start-HuggingFaceImport` (`scripts/Get-ModelAcquisition.ps1:153-278`) launches a background job that downloads the file, creates a Modelfile, runs `ollama create` to import, and warm-starts the model. Model names prefixed with `hf-` (e.g., `hf-anthropic-qwen`) identify HF imports; `Start-ModelAcquisitionPull` skips registry pull for these. Falls back to smallest curated model if HF search/download/import fails at any point.

### 5. Verbose, human-readable logging throughout — **Status: Done**
**As a** user **I want** clear logs of every step **so that** I can see what's happening and trust the automation.
- Reuse the logging shape from [`01-Local-AI-Platform-Blueprint.md`](01-Local-AI-Platform-Blueprint.md#logging-model) (UTC timestamp, action, result, provider, model, message).
- Emit a log line for: sources checked, hardware profile detected, candidates found, candidate chosen and why, pull started/progress/finished, model started.
- Messages must be plain language, not just codes (e.g. "Your PC has 16GB RAM and no dedicated GPU — selected llama3.1:8b-q4_K_M as the best fit" rather than a bare model ID).
- Priority: **P0**
- Implemented: `Write-AuditLog` (`scripts/Start-AI.ps1:25`) writes JSON-lines plus colored `Write-Host` output at every step listed above, including inside the background pull job via `Write-JobAuditLog`.

## Out of scope (for now)
- Multi-model concurrent serving.
- Cloud-hosted model fallback for acquisition (cloud providers remain chat-completion fallback only, per the existing fallback matrix).
- GPU driver installation or CUDA/ROCm setup.

## Open questions
- ~~Where does the hardware-to-model-size mapping table live~~ — resolved: hardcoded in `config/models.json` (`localModels` sizes + `fallbackOrder`).
- ~~Should the user be able to override the auto-selected model~~ — resolved: yes, the `-Model` parameter on `Start-AI.ps1` skips auto-selection entirely (`scripts/Start-AI.ps1:273`).
- ~~Should model sizing prefer RAM over VRAM when RAM is larger~~ — resolved: yes, always prefer RAM; Ollama offloads to CPU/RAM automatically. Fixed in `Get-ModelSizingCeilingGB` (`scripts/Get-ModelAcquisition.ps1:88`).
