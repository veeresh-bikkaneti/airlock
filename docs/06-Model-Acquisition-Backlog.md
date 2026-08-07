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

### 4c. Fallback when a background HuggingFace import fails after selection — **Status: Backlog**
**As a** user **I want** the platform to fall back to a curated model **so that** a failed HuggingFace download or `ollama create` doesn't leave me with no running model at all.
- Today `Start-HuggingFaceImport` runs as a fire-and-forget background job; if the download or `ollama create` import fails, the failure is only visible in the audit log — the user is told their model is "pending" and nothing ever starts.
- Needs the platform to detect job failure/timeout and retry with the next-best curated model, or clearly surface the failure instead of silently leaving the user without a working model.
- Priority: **P2**

### 6. Auto-install Ollama itself when missing — **Status: Done**
**As a** user **I want** double-clicking `Start-AI.bat` to work even if I've never installed Ollama **so that** setup is genuinely zero-install, not "zero-install except the one thing you have to do first."
- Detect Ollama missing (not on PATH, not at the default per-user install path).
- Install via `winget install --id Ollama.Ollama -e --silent`, no interactive prompt, matching the no-prompt precedent for model pulls in ADR-001.
- Refresh `$env:Path` for the current process after install so `ollama` calls work without a shell restart.
- Fall back to today's manual-install error message if `winget` itself isn't available.
- New `-NoAutoInstallOllama` switch opts out for managed/locked-down machines.
- Priority: **P1**
- Design: [`ADR-002-ollama-auto-install.md`](adr/ADR-002-ollama-auto-install.md).
- Implemented: `Install-OllamaIfMissing` (`scripts/Get-ModelAcquisition.ps1:5-67`) checks PATH and default install path, then uses `winget install` if Ollama is missing and winget is available. Integrated into `scripts/Start-AI.ps1` with a call after the PowerShell version check (lines 171-177) and guarded by the new `-NoAutoInstallOllama` switch. Audit logging added for all install outcomes (STARTED/SUCCESS/FAILED).

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

## vLLM Backend Choice (ADR-003) — Review Follow-ups
Swarm review (Sonnet orchestrator + Haiku expert reviewers) of the vLLM/Ollama backend chooser feature, 2026-08-06. Two real bugs found and fixed on `feat/ollama-auto-install`; two lower-severity gaps deferred below.

**Fixed this pass:**
- `Stop-AI.ps1` audit log hardcoded `provider: "ollama"` regardless of which backend was actually stopped — now reads the detected `$ActiveBackend`.
- `Start-VLLM.ps1`'s "reuse existing healthy container" fast path exited without writing `active-port.json`/`active-provider.json`, so `Stop-AI.ps1` would default to Ollama and leave a reused vLLM container running untouched. Extracted `Write-VLLMState` so both the fresh-launch and reuse paths persist state identically.

### 7. Harden Stop-AI.ps1 against a stale active-provider.json — **Status: Backlog**
**As a** user **I want** `ai-stop` to stop whichever backend is actually running **so that** a stale or missing state file (e.g. after a crash or manual `docker kill`) can't leave a backend orphaned.
- Today `Stop-AI.ps1` trusts `active-provider.json` alone; if it's stale, it can try to stop the wrong backend.
- Needs `Stop-AI.ps1` to also probe reality (`docker ps` for the vLLM container name, `Get-Process ollama*`) rather than relying solely on the state file.
- Priority: **P2**

### 8. Generalize `ai-health` for the vLLM backend — **Status: Backlog**
**As a** user **I want** `ai-health` to report correctly regardless of which backend is active **so that** I get a real health picture, not an Ollama-only one.
- `ai-health` (`scripts/profile-helpers.ps1`) checks an Ollama-specific process count, an Ollama-only firewall rule name (`AI-Platform-Ollama-Block-*`), and Ollama's `/api/tags` endpoint — none of which apply when vLLM is active.
- Needs backend-aware branching (read `active-provider.json`, check the right process/container and firewall rule name per backend) — not a one-line endpoint swap.
- Priority: **P2**

## Full-Repo Review (2026-08-06)
Sonnet orchestrator + 6 Haiku expert reviewers across scripts/, config/, hermes-container/, src/ (VS Code extension), and build entry points. Every finding was independently re-verified before acting on it — several Haiku findings turned out false or overstated and were rejected (see task history for detail).

**Fixed this pass:**
- `scripts/Invoke-CommitReview.ps1` — `git restore --staged` failures on BLOCKED/declined files were silently swallowed, so a failed unstage would fall through to the final `git commit` anyway. This defeated the script's entire purpose (preventing secret leaks). Now hard-aborts on unstage failure.
- `src/extension.ts` — `selectModel()`/`switchModel()` had unhandled `JSON.parse()` on `models.json`; malformed config now shows a clean error instead of an uncaught exception.
- `tsconfig.json` — no `include` array meant `tsc -p .` (the extension's own build command) pulled in the unrelated untracked `my-video/` directory and failed outright. Added `"include": ["src"]`. Verified clean via `npm install && npx tsc --noEmit`.
- `scripts/profile-helpers.ps1` — a partially-commented-out "print command summary" block left 7 `Write-Host` calls executing unconditionally on every dot-source (every new shell, every `ai-start`), printing a broken partial command list. Finished commenting it out per the block's own stated intent.
- `docs/COMPONENTS.md` — security checklist falsely claimed API keys live in a "PowerShell SecretManagement vault"; actual code (`ai-auth-set`) writes plain JSON to `~/.ai-platform/config/auth.json`, contradicting the doc's own earlier line. Corrected.

### 9. Pin hermes-container base image to a digest — **Status: Backlog**
**As a** maintainer **I want** the Hermes container's base image pinned to an immutable digest **so that** a `node:24-bookworm-slim` upstream update can't silently change the build.
- `hermes-container/Dockerfile:1` uses a mutable tag. Needs the real digest (`docker pull node:24-bookworm-slim && docker inspect ... RepoDigests`) — not fabricated here.
- Priority: **P3** (low risk for a single-user local tool)

### 10. Make Test-ModelSelection.ps1 test the real Select-BestModel — **Status: Backlog**
**As a** maintainer **I want** the model-selection test to exercise the actual production function **so that** a regression in `Select-BestModel` (`scripts/Get-ModelAcquisition.ps1:361`) gets caught.
- `scripts/Test-ModelSelection.ps1:10-18` defines its own `Select-ModelForMemory` copy instead of calling `Select-BestModel` — the real function includes HF fallback/discovery the test never exercises.
- Feeds into the queued `/ruflo-testgen:testgen` pass.
- Priority: **P2**

### 11. Regenerate or delete the stale artifact manifest — **Status: Backlog**
**As a** maintainer **I want** `docs/artifact-manifest.json` to either be accurate or gone **so that** it doesn't look like a live integrity check when it isn't.
- 5 of 7 tracked docs have mismatched hash/size; `07-Quickstart-Playbook.md` and `COMPONENTS.md` were never added. Confirmed nothing in the codebase reads or verifies this file — zero functional risk, purely stale metadata.
- Priority: **P3**

### Rejected/downgraded findings (for the record)
- `$LASTEXITCODE` reliability after `| Out-Null` — empirically disproven (tested directly).
- `ai-switch` using `/api/tags` instead of `/v1/models` — false positive, that function is intentionally Ollama-only per ADR-003's explicit scope.
- `Get-ModelAcquisition.ps1` background-job lifecycle — real limitation but already documented in-code as an accepted tradeoff with the same upgrade path suggested.
- `$LogFile` and `Get-ModelSizingCeilingGB` "unused" — both false, both have live callers.
- VS Code `pollTimer` not in `context.subscriptions` — overstated; `deactivate()` already clears it through the same lifecycle VS Code uses to dispose subscriptions.
- Hardcoded `127.0.0.1` in the extension and elsewhere — intentional loopback-only invariant per ADR-003, not a bug.

## Documentation & Diagram Pass (2026-08-06)
User asked for beginner-friendly architecture diagrams (flowchart, entity diagram, workflow diagram) and a genuinely 1-click install. README already had 3 of the 4 diagram types (architecture flowchart, backend-selection flowchart, start/stop sequence diagram) from the earlier vLLM work — added the missing **entity diagram** (`erDiagram` of provider-policy/active-port/active-provider/models-registry/auth/commit-policy/audit-log relationships).

**Fixed:**
- README's "Installation" section didn't mention `setup.ps1` exists at all — it spelled out 5 manual commands instead of the actual one-liner. Now leads with `.\setup.ps1`, manual steps moved to a collapsed fallback.
- `setup.ps1`'s own final message told the user to copy a `config/.env.template` that doesn't exist in this repo. Fixed to point at the real `ai-auth-set` flow.
- **Bigger one**: `PLAYBOOK.md`, `docs/02-Windows-Implementation-Guide.md`, and `docs/01-Local-AI-Platform-Blueprint.md` all instructed installing/registering a PowerShell SecretManagement vault (`Install-Module`, `Register-SecretVault`, `Set-Secret`) as the way to store API keys. Verified by grep across every `.ps1` file: `Get-SecretVault` is called exactly once (`Start-AI.ps1:400`), for an existence check only — nothing anywhere calls `Get-Secret`/`Set-Secret`. The real, working mechanism is `ai-auth-set` writing plain JSON to `auth.json`. Following the vault instructions as written would waste a beginner's time setting up something the platform never reads from. Corrected all three docs; renumbered `docs/02`'s steps after merging two into one.
- README's Component Guide / Architecture Files tree / `COMPONENTS.md` config table all listed `.env.template` and `.aider.conf.yml.template` (don't exist) and were missing `claude-settings.json.template`, `hermes-config.json.template`, `jcode-config.toml.template`, `pi-models.json.template` (do exist). Synced to reality in both files.

### 12. `docs/02-Windows-Implementation-Guide.md` Step 1 creates a dead `.env` file — **Status: Backlog**
**As a** user **I want** the Windows implementation guide to only ask me to create files the platform actually reads **so that** I'm not doing pointless setup work.
- Step 1 creates `~/.ai-platform/.env` and sets ACLs on it. Confirmed by grep: no script reads this path. Lower priority than the vault fix above since it's just an unused empty file, not a wasted module install.
- Priority: **P3**

## Cleanup candidates (unrelated to any feature, flagged not actioned)
- 4 stale `worktree-agent-*` git branches.
- Stray untracked `$null` file in repo root (cmd.exe redirect artifact, harmless junk).
- Untracked `my-video/` directory in repo root (unrelated Remotion project) — this is what broke `tsc` above; worth relocating out of the repo root even though `tsconfig.json` no longer chokes on it.
