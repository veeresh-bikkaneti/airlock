# ADR-016: `ai-agent-start` is the coding door; Unsloth GGUF + llama-server is how it boots

## Status
Accepted. Implemented on `main` via [#43](https://github.com/veeresh-bikkaneti/airlock/pull/43)
(`feat(adr-016): implement ai-agent-start as the Unsloth coding door`).
Depends on AIR-015 ([#41](https://github.com/veeresh-bikkaneti/airlock/pull/41)).

Unit tests pass. Live `ai-agent-start` on the author ThinkPad is still open
([PENDING.md](PENDING.md)).

## Context

AIR-015 proved one combination **3/3** with real `read`/`write` tool events: Unsloth Qwen3.8-27B UD-Q3_K_XL served by `llama-server`, driven by Pi in `hermes-container`. That proof is not a product door.

Today, after #41:

- `ai-start` still ranks Ollama `models.json` by VRAM (AGENT-001). Chat default can still be a 0/6 agentic model.
- `acquisition.kind: huggingface-gguf` is a label. The only HF importer does `ollama create`. The live GGUF was pre-placed at `~/.ai-platform/models/Qwen3.8-27B-UD-Q3_K_XL.gguf` (13,146,393,504 bytes).
- `Start-LlamaCppRuntime` has **no production caller**. `Start-AgentSession` only adopts `llamacpp-instance.json` or fails. Default `-HealthTimeoutSec` is 30; the 13 GB load needed 300.
- `run-hermes.ps1` / AGENT-002 already tell the user to run `ai-agent-start`. That function does not exist in `profile-helpers.ps1`.
- `hermes-container/config/models.json` `ollama-local` does not list the Unsloth `modelRef`. Pi warns and uses a custom id.
- `candidateOnly: false` is schema-valid and is **not** a certificate. `Start-AgentSession` still must not auto-select the promoted profile.

xLAM proxy stays a dead end (ADR-013 D5). opencode `--auto` ~282K skill dump is AIR-017, not a gate here.

## Decision

**D1. Two doors.** `ai-start` remains chat/completion (Ollama/vLLM). `ai-agent-start` is the only coding door. `ai-code` / Pi worker / `ai-hermes-start` refuse to run without an unexpired `active-agent.json`. `ai-switch` (Ollama model change) invalidates that certificate.

**D2. Default coding profile is `llamacpp-qwen38-ud-q3-k-xl`.** Explicit `-Profile` is required to use any other catalogue entry. Installed-but-unrequested, including the promoted Unsloth profile, is never auto-selected (already true; keep it).

**D3. Implement `huggingface-gguf` for llama-server only.** Map `modelRef` `unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL` → file `Qwen3.8-27B-UD-Q3_K_XL.gguf` under `~/.ai-platform/models/`. `requiresConfirmation: true` is enforced (prompt or `-Confirm:$false` only after a recorded yes). Record bytes + SHA-256 in the certificate provenance. **Do not** `ollama create`. If the file exists and byte size is exactly `13146393504`, skip download and treat as the evidence-bound artifact. If size differs (Dynamic 3.0 re-publish), do **not** inherit the 3/3; require a live contract (`-ForceVerify`).

**D4. `ai-agent-start` starts `llama-server`.** Call `Start-LlamaCppRuntime` with the profile's `runtimeArgs` and `initialContext`, `-HealthTimeoutSec 300` (or raise the adapter default to 300 — 30s is a footgun). Fail closed if `/health` is not ready. Then `/props` template verification must Pass.

**D5. Proving harness is Pi (`pi-worker`), not opencode.** Reuse `Invoke-AirlockPiCapabilityContract`. Do not re-gate this profile through opencode (ADR-013 D3 / AIR-017).

**D6. Certificate is the verdict, not the JSON flag.** Publish `active-agent.json` only on harness pass. `candidateOnly: false` means "this profile has a bound live pass on the author's hardware"; it does not skip D4–D5 on a different machine or a different GGUF.

**D7. Refuse Ollama coding certificates.** Do not publish `active-agent.json` for `runtime: ollama` profiles that have no passing live contract in this repo's evidence (qwen2.5-coder:7b, qwen3-coder:30b 0/6, devstral-small-2:24b). Chat via `ai-start` is unchanged.

**D8. Register the Unsloth id in Pi's catalogue.** Add `unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL` to `hermes-container/config/models.json` `providers.ollama-local.models`. Stops the "custom model id" warning; a future Pi validator must not hard-fail this path.

**D9. Minimum VRAM gate before start.** If `nvidia-smi` reports free VRAM below `minimumFreeVramGiB` (14), refuse to start. This is the cheap slice of FIT-ADAPTERS-001. Full llama-server residency measurement stays a follow-up.

## What this explicitly does not change

- `Select-BestCuratedModel` / `ai-start` chat ranking (still Ollama-by-VRAM).
- Unsloth recommended sampling / `--chat-template-kwargs reasoning_effort medium` / vision / MTP. Verified flags stay `--jinja --flash-attn on --n-gpu-layers all --reasoning-effort low`, ctx 8192.
- xLAM proxy. vLLM `local-limited`. opencode 282K upstream issue (AIR-017).
- Re-running the GPU 3/3 in CI.

## Consequences

**Positive** — a user can type `ai-agent-start` and get the one path that actually completed a tool loop, or a fail-closed explanation.

**Negative** — first run downloads ~13 GB and needs ~14 GiB free VRAM plus Docker for Pi. A fresh Unsloth re-quant does not inherit the 3/3.

## Evidence this ADR binds to

- `docs/adr/evidence/ADR-013-unsloth-pi-live-verification.md`
- `docs/adr/ADR-013-llama-cpp-pi-agentic-path.md`
- `docs/adr/ADR-012-validated-local-agent-bootstrap.md` (AGENT-001, AGENT-002, AGENT-006, FIT-ADAPTERS-001)

## Next

See [PENDING.md](PENDING.md). Immediate leftover for this ADR: live
`ai-agent-start` on the ThinkPad (13 GB load + Pi Docker). Quant
step-downs are [ADR-018](ADR-018-unsloth-quantization-strategy.md) and
do not change D2.
