# Pending work (after AIR-014 / 015 / 016 on `main`)

Index only. Evidence still lives in the ADRs named below. Do not treat a
checkbox here as a certificate.

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
2. **AGENT-001** — `ai-start` still ranks Ollama `models.json` by VRAM. Chat default on this GPU is `qwen2.5-coder:7b` (known-failed). Do not silently make it coding-ready. Tracked in [ADR-012](ADR-012-validated-local-agent-bootstrap.md).
3. **FIT-ADAPTERS-001** — ADR-016 D9 is the cheap VRAM floor. Full llama-server residency (layers all vs CPU spill) is still unmeasured.
4. **AIR-017 / T087** — opencode `--auto` ~282K skill dump; vLLM has zero live agentic verdict and is not marked `local-limited` in scripts. Not a gate for Unsloth + Pi.
5. **ADR-018 follow-up** — `UD-Q4_K_XL` (17.6 GB) needs a 24 GB card and a new 3/3. Do not inherit the Q3_K_XL certificate. Helper exists; no coding profile yet.
6. **Linux port Phase 1** — spec at `docs/superpowers/specs/2026-08-19-linux-port-design.md`. Unverified on Ubuntu.
7. **HF import job death** — `docs/06-Model-Acquisition-Backlog.md` story 4c. Chat path only.

## Do not merge / do not retry

| Item | Why |
|---|---|
| `feature/spec-kit-adoption` | Spec-kit constitution treats `CLAUDE.md` as source of truth (Ruflo lock-in). ADR-014 D1. |
| xLAM proxy / `xlam-proxy/` | ADR-013 D5. Ceiling is extraction, not shell/EOS. |
| Ollama coding certificates | qwen2.5-coder:7b, qwen3-coder:30b 0/6, devstral-small-2:24b. ADR-016 D7. |
| 1-bit / 2-bit Unsloth as the coding default | Quality floor. ADR-018. |

## Hardware this evidence is bound to

Lenovo ThinkPad P16 Gen 2 (`21FA002BUS`), i9-13950HX (24C/32T), NVIDIA RTX 5000 Ada Laptop **16376 MiB** total. Intel UHD is the iGPU — ignore `Win32_VideoController.AdapterRAM` (UInt32 overflow on the Ada card).
