# ADR-005: Size local model selection against free VRAM, not free system RAM

## Status
Accepted — supersedes [ADR-001](ADR-001-model-acquisition-placement.md) decision point 3 only. The rest of ADR-001 (acquisition placement, curated-list-first discovery, HF fallback, session-scoped pull) is unaffected and stays Accepted.

## Context
ADR-001 decision point 3 set the model-size ceiling to `FreeMemGB` (system RAM), reasoning that Ollama offloads layers that don't fit VRAM to CPU, so a model that doesn't fit the GPU still *runs* — GPU only affects speed, not feasibility.

That reasoning is correct about *whether* a model runs. It ignores *whether the result is usable* for this platform's actual use case: an interactive agentic coding loop. Evidence from a real session (`docs/bugs/PBI-airlock-local-fallback-architecture.md`, Child item 1):

- Sizing selected `qwen3-coder:30b` (18 GB) because it "fits 87.7 GB available" — system RAM.
- The same startup line reported 15 GB free VRAM on a 16 GB GPU. An 18 GB model cannot fit; Ollama spilled layers to CPU.
- Measured baseline on the same machine: `qwen2.5-coder:7b` (fits fully in VRAM) runs at 91.55 tok/s. A partially CPU-offloaded 30B model runs at a small fraction of that — minutes per turn in an agentic loop.

For a background batch job, RAM-only sizing is defensible — it finishes eventually. For an interactive tool-calling loop, a slow "working" model is functionally the same as a broken one: the user gives up before the turn completes. The larger model's quality edge is irrelevant if each turn takes minutes.

## Decision
`Get-ModelSizingCeilingGB` sizes against **free VRAM** when a GPU is present, not free system RAM:

- If `Resources.GpuTotalGB -ne "N/A"`: ceiling is `Resources.GpuFreeGB`.
- If no GPU detected: ceiling remains `Resources.FreeMemGB` (RAM is the only constraint that exists).
- The existing 20% headroom multiplier in `Select-BestCuratedModel` (KV cache growth, context window) is unchanged — it now applies to the VRAM figure instead of the RAM figure.
- **Already-pulled models are preferred over models requiring a download**, all else equal — `Select-BestCuratedModel` checks `ollama list` before treating a same-tier download as the winner. Pulling an 18 GB model when a working 4.7 GB model already sits on disk is never the right default, independent of the sizing ceiling.
- When the winning model does not fit VRAM (no VRAM-resident candidate exists at all), it is still selected, but the startup banner and audit log say plainly that it will run partially on CPU and be slow — this is a fallback of last resort, not a silent choice.

## Consequences

**Positive**
- The auto-selected model is one the interactive loop can actually use at usable speed, on GPU-equipped machines — the common case this platform targets.
- Selection rationale (free VRAM, model size, headroom, rejected candidates and why) is logged, matching the acceptance criteria in the linked PBI.

**Negative**
- On a machine with a GPU too small for any curated model but with ample system RAM, this ADR now selects a smaller (or CPU-fallback) model where the old logic would have picked a larger one. This is intentional — see Context.
- Two sizing paths now exist (VRAM-present vs. no-GPU) instead of one. `Test-ResourceAvailability` already computes both `FreeMemGB` and `GpuFreeGB`; no new probing was added.

**Neutral**
- `ADR-001`'s architecture diagram and the other three decision points are untouched.

## Alternatives considered
- **Keep RAM-only sizing, fix only child items 2–5 of the PBI.** Rejected: item 1 is the PBI's own "root of the killing the response time complaint" — the wiring fixes (item 2) are necessary but not sufficient if the auto-selected model still spills to CPU.
- **Size against `min(FreeMemGB, GpuFreeGB)` unconditionally.** Rejected: on a no-GPU machine this degenerates to RAM sizing anyway (current behavior, unchanged), so the explicit GPU-presence branch is clearer to read and log than a `min()` that's a no-op half the time.
