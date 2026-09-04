# ADR-018: Unsloth Dynamic 3.0 quant strategy on this 16 GB Ada card

## Status
Accepted on `feature/adr-018-unsloth-quant-strategy`. Encodes the ladder in
`scripts/Get-HuggingFaceGguf.ps1`. Does **not** change the AIR-016 coding
default (`llamacpp-qwen38-ud-q3-k-xl`). Does not add a Q4 profile.

## Context

AIR-016 boots one file: Unsloth `Qwen3.8-27B-UD-Q3_K_XL.gguf`,
13,146,393,504 bytes (Dynamic 3.0). That is the only GGUF with a 3/3 Pi
tool-event pass on the author's RTX 5000 Ada Laptop (16 GB, 16376 MiB total).

Unsloth publishes a full Dynamic 3.0 ladder in
[`unsloth/Qwen3.8-27B-GGUF`](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF).
A 4-bit XL is their quality pick on **24 GB**. On **16 GB** the same file
spills. Agents that "just try Q4" restart the VRAM-spillover loop already
in `AGENTS.md`.

A Dynamic 2.0 `UD-Q3_K_XL` pulled before ~2026-08-19 is a **different
artifact** (13,441,059,904 bytes). Same filename. Byte size is the
discriminator (AIR-016 D3).

## Decision

**D1. Coding default stays `UD-Q3_K_XL`.** 13.1 GB file, 14 GiB free-VRAM
floor, `--n-gpu-layers all`, ctx 8192. Inherit the 3/3 only when the file
on disk is exactly 13,146,393,504 bytes.

**D2. The ladder is a strategy, not a second coding door.**
`Resolve-AirlockUnslothQuantStrategy` returns a recommendation. It does
not change `ai-agent-start`'s default profile. A step-down quant is
`candidateOnly`: live contract required, no inherited certificate.

**D3. 16 GB Ada class (author hardware) — Unsloth Dynamic 3.0 sizes:**

| Quant | File | 16 GB Ada | Coding role |
|---|---|---|---|
| UD-IQ2_XXS | 7.27 GB | fits | last-resort 12 GB class; quality cost is real |
| UD-Q2_K_XL | 9.83 GB | fits | step-down if free VRAM is 11–12 GiB |
| UD-IQ3_XXS | 10.9 GB | fits | step-down if free VRAM is 12–14 GiB (more KV) |
| **UD-Q3_K_XL** | **13.1 GB** | **coding default** | **14 GiB floor; only 3/3** |
| UD-IQ4_XS | 14.3 GB | tight / spill at 8k | not a coding profile here |
| UD-Q4_K_S | 15.4 GB | spill | 24 GB class |
| UD-Q4_K_XL | 17.6 GB | spill | Unsloth's 24 GB pick; needs a new 3/3 |
| UD-Q5_K_XL and up | ≥18.7 GB | no | 32 GB+ |

**D4. Step-down is only for VRAM, never for "maybe better quality."**
On a 16 GB card, Q4 is not an upgrade. On a 24 GB card, Q4_K_XL may be
tried as a **new** profile (`candidateOnly: true`) — it does not inherit
Q3's certificate.

**D5. Do not `ollama create` any of these.** llama-server GGUF only.
Ollama Qwen3.8-27B already spilled on this GPU.

**D6. 1-bit (UD-IQ1_*) is not a coding candidate.** Fits, but the quality
floor is below what the Pi contract is for.

## What this explicitly does not change

- AIR-016 D2 default profile and D9 14 GiB floor for Q3_K_XL.
- Verified `runtimeArgs` (`--jinja --flash-attn on --n-gpu-layers all --reasoning-effort low`).
- Vision / MTP. MTP wants 1–2 GB extra; not enabled on the 16 GB coding path.
- Re-running GPU 3/3 in CI.

## Consequences

**Positive** — a future agent can pick a smaller Unsloth quant when the
Ada card is busy, without guessing Q4 or Ollama.

**Negative** — step-down quants have **zero** live agentic evidence.
They fail closed until a contract pass.

## Evidence this ADR binds to

- `docs/adr/evidence/ADR-013-unsloth-pi-live-verification.md` (3/3, 16376 MiB).
- Hugging Face `unsloth/Qwen3.8-27B-GGUF` Dynamic 3.0 table (2026-09).
- AIR-016 D3 evidence bytes `13146393504`.

## Next

Live-verify `ai-agent-start` on the ThinkPad. Q4_K_XL only after a 24 GB
card (or a measured all-layers fit) plus a new 3/3. See [PENDING.md](PENDING.md).
