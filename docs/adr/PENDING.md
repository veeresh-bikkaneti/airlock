# Pending work (after AIR-014 / 015 / 016 on `main`)

Index only. Evidence still lives in the ADRs named below. Do not treat a
checkbox here as a certificate.

**Product north star:** anyone on any PC. Inspect the box, pull a model that
fits *that* box, prove coding on *that* box, persist memory so a session can
resume. The ThinkPad P16 / RTX 5000 Ada numbers below are the evidence host,
not the target market. Item 8 (portable coding-door detection) is the core
requirement. A bound 3/3 does not mean "Airlock works."

## Landed on `main`

| ID | What | PR |
|---|---|---|
| ADR-014 | Portable `AGENTS.md` operating contract | [#40](https://github.com/veeresh-bikkaneti/airlock/pull/40) |
| ADR-013 / AIR-015 | Unsloth + llama-server + Pi 3/3, `candidateOnly: false` | [#41](https://github.com/veeresh-bikkaneti/airlock/pull/41) |
| ADR-016 spec | `ai-agent-start` is the coding door | [#42](https://github.com/veeresh-bikkaneti/airlock/pull/42) |
| ADR-016 impl | GGUF acquire, llama-server start, cert on live pass | [#43](https://github.com/veeresh-bikkaneti/airlock/pull/43) |
| ADR-018 | Unsloth Dynamic 3.0 quant ladder vs RTX 5000 Ada 16GB | this branch |

## Open (do next, in this order)

1. ~~**Live `ai-agent-start` on the author ThinkPad**~~ — **CLOSED 2026-09-05.** Ran `Start-AgentSession.ps1 -Profile llamacpp-qwen38-ud-q3-k-xl -Harness pi-worker -DownloadConfirmed -ForceVerify` on the bound hardware (LENOVO 21FA002BUS, RTX 5000 Ada 16376 MiB match confirmed). Exit 0, `SUCCESS: Contract passed - certificate atomically replaced`. Certificate fresh (10s old), GGUF byte-match (13,146,393,504 bytes), `transportReturnedValidToolEvents: true`, verdict pass — `-ForceVerify` bypassed cache, so this is a genuine live trial, not a replay. Verification-only run, no repo commits.
2. **AGENT-001** — still **open**. Do not treat it as closed. Chat ranking changes (separate VRAM-fit chat pick from coding eligibility) are landing on this branch (`feat/airlock-coding-door-gaps`); that is not a certificate and does not close AGENT-001. On ~15 GB free VRAM the chat pick is now `qwen3:14b` (unproven), not `qwen2.5-coder:7b`. The 7b only wins below ~10.8 GB (20% headroom on its ~9 GB size) as the only class that fits — still known-failed, still not coding-ready. Tracked in [ADR-012](ADR-012-validated-local-agent-bootstrap.md). ThinkPad live run (item 1) stays CLOSED.
3. **FIT-ADAPTERS-001** — ADR-016 D9 is the cheap VRAM floor. Full llama-server residency (layers all vs CPU spill) is still unmeasured.
4. **AIR-017 / T087** — opencode `--auto` ~282K skill dump; vLLM has zero live agentic verdict and is not marked `local-limited` in scripts. Not a gate for Unsloth + Pi.
5. **ADR-018 follow-up** — `UD-Q4_K_XL` (17.6 GB) needs a 24 GB card and a new 3/3. Do not inherit the Q3_K_XL certificate. Helper exists; no coding profile yet.
6. **Linux port Phase 1** — spec at `docs/superpowers/specs/2026-08-19-linux-port-design.md`. Unverified on Ubuntu.
7. ~~**HF import job death**~~ — **CLOSED on this branch.** Chat pulls/imports are detached (`Invoke-DetachedModelPull.ps1` + `model-pull.json`). Remaining 4c work is fallback-on-fail after a worker actually fails, not parent-session job death. See `docs/06-Model-Acquisition-Backlog.md` story 4c.
8. **Portable capability detection for the coding path** — core requirement, still **open**. **Landing on `feat/airlock-coding-door-gaps`:** hardware-sized coding default with **no `-Profile`**. `Resolve-AirlockHardwareSizedCodingProfile` + the Unsloth Dynamic 3.0 ladder (`Resolve-AirlockUnslothQuantStrategy` in `Get-HuggingFaceGguf.ps1`) sizes Qwen3.8-27B to *this* machine: VRAM first (16 GB class → UD-Q3_K_XL; smaller GPUs step down, candidate-only), then **RAM mmap / CpuOffload** when the GGUF fits in system RAM (`--n-gpu-layers 0`, slow, live Pi, never inherit a GPU 3/3). Tiny RAM still refuses. That is **not** auto-select of an installed-but-unrequested catalogue entry (ADR-012 §7.1 still holds — `Resolve-AirlockProfileSelection` does not pick "whatever is on disk"). A new machine still needs its own live Pi contract pass; do not inherit the ThinkPad 3/3. **Not GLM-class.** AGENT-001 (item 2) stays **OPEN**. Item 5 (`UD-Q4_K_XL` / 24 GB, new 3/3) stays **open** — helper exists, no coding profile, no inherited certificate. Item 6 (Linux) stays **open**. Related: item 3 (FIT-ADAPTERS-001). **Already in tree:** `Resolve-AirlockPortableFitState` fails fast with a "what fits this machine" message before GGUF download.
9. ~~**Coding-path memory routing**~~ — **CLOSED 2026-09-08.** `ai-agent-start` routes through memory-service when it's running, and real cross-session recall/remember now works for coding sessions — not just passthrough. Resolved the embeddings gap without Ollama: llama-server has native `--embedding` mode and serves OpenAI-compatible `/v1/embeddings`, so a second, small, CPU-only llama-server instance (EmbeddingGemma-300M, ~172MB Q4_0, `Start-AirlockEmbeddingRuntimeIfNeeded` in `llamacpp.ps1`) serves embeddings with zero AGENTS.md tension (never touches Ollama, never touches port 12345). New `LlamaCppEmbeddingFunction` (`memory-service/app/embeddings.py`) and a separate Chroma store (`_coding_store`, `CHROMA_DIR_CODING`) keep coding memories isolated from chat's Ollama-embedded ones (different models, different vector dimensions). `/coding/v1/chat/completions` now does real recall+injection before forwarding (works for both streaming and non-streaming — injection happens before the request is sent, so it isn't blocked by streaming the way persistence would be), and `/coding/v1/memory/remember` persists explicitly, mirroring the chat path's own always-manual remember semantics. Verified live, end to end: remembered a real fact via `/coding/v1/memory/remember`, asked an unrelated-looking question through `/coding/v1/chat/completions` (both streaming and non-streaming) using the exact llama-server backend, got `airlockMemory.augmented: true` and a correct answer citing the remembered fact in the model's own reasoning trace. **Two real bugs found only by running it, not by reading the code:** (1) `Start-LlamaCppRuntime`/`Get-AirlockLlamaCppBaseUrl`/`Stop-LlamaCppIfOwned` all wrote/read one hardcoded `llamacpp-instance.json` — a second concurrent instance (the embedding runtime) would have clobbered the coding model's own record; fixed with a `-InstanceStateFileName` parameter, defaulted to the original filename for full backward compatibility. (2) llama-server's `--embd-gemma-default` convenience flag silently ignores `--port` and always binds a fixed port (8011) — every start "timed out" against the port Airlock actually requested and was polling; fixed by downloading the GGUF explicitly (`Get-AirlockEmbeddingGguf`) and passing `-m <path>` instead, which respects `--port` correctly.

## Do not merge / do not retry

| Item | Why |
|---|---|
| `feature/spec-kit-adoption` | Spec-kit constitution treats `CLAUDE.md` as source of truth (Ruflo lock-in). ADR-014 D1. |
| xLAM proxy / `xlam-proxy/` | ADR-013 D5. Ceiling is extraction, not shell/EOS. |
| Ollama coding certificates | qwen2.5-coder:7b, qwen3-coder:30b 0/6, devstral-small-2:24b. ADR-016 D7. |
| 1-bit / 2-bit Unsloth as the coding default | Quality floor. ADR-018. |

## Hardware this evidence is bound to

Lenovo ThinkPad P16 Gen 2 (`21FA002BUS`), i9-13950HX (24C/32T), NVIDIA RTX 5000 Ada Laptop **16376 MiB** total. Intel UHD is the iGPU — ignore `Win32_VideoController.AdapterRAM` (UInt32 overflow on the Ada card).
