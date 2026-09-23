# Honest fit — remaining llmfit gap

Status: binding for `feature/honest-quant-pick`. Do not merge to main until the architect review and the test scripts below pass.

## Already on this branch (do not redo)

- Closed Unsloth Qwen3.8-27B ladder. Highest quant whose VRAM floor fits. Steps up (Q4/Q5/Q6/Q8) and down (IQ3/Q2/IQ2).
- `UD-IQ4_XS` is not a coding pick (spills at 8k on 16 GB).
- Fit words: Perfect ≤60%, Good ≤85%, Marginal ≤98%, else TooTight. CPU never Perfect.
- Inherit the recorded 3/3 only for `UD-Q3_K_XL` on a 16 GB NVIDIA-class card (total 15–18 GB). Everyone else is candidateOnly.
- Named profiles exist. Catalogue rows exist for the step-up quants.
- Fit is not a certificate. Pi 3/3 still gates coding.

## Global constraints

- Do not shell out to llmfit. Do not import its catalog or its quality score.
- Do not copy llm-checker source (NPDL). AMD text is original.
- One runtime stays llama-server. No MLX, LM Studio, or Docker runtime.
- Do not sum VRAM across GPUs. One GGUF uses one GPU.
- Do not partial-offload a quant that does not fit (`--n-gpu-layers` stays `all` or `0`). ADR-005.
- Unknown vendor does not inherit. Empty vendor is UseCandidate even when the numbers match the ThinkPad.
- Half context does not inherit, even when the quant is `UD-Q3_K_XL`.
- A speed number is an estimate or a local sample. It never sets InheritEvidence.
- WhatIf writes no doctor file.
- Tests: `pwsh -File scripts/Test-AgentStart.ps1` and `pwsh -File scripts/Test-AgentProfileHelpers.ps1`. No live GPU.

## Task 1 — Context that fits

`Resolve-AirlockUnslothQuantStrategy` gains `ContextTokens` on every pick (8192, 4096, or 0 on refuse).

Floor in the ladder is the 8192-token floor. If free VRAM misses that floor but meets `FileGb + (MinimumFreeVramGiB - FileGb) / 2`, keep that quant and set `ContextTokens` to 4096. Only then step down. Do not use a model's advertised max context.

13.0 GiB free still steps down to `UD-IQ3_XXS` at 8192. A free pool that clears the half-context floor for Q3 but not the 14 GiB floor stays on Q3 at 4096, InheritEvidence false.

## Task 2 — GPU pool, unified memory, AMD note

New pure function `Resolve-AirlockGpuPool`. Input is a list of GPUs: name, vendor, total GiB, free GiB, unified (bool). Plus free RAM GiB.

- Pick the single GPU with the largest free GiB. Do not sum.
- Reason names which GPU was used and that others were not added.
- Unified memory is not discrete VRAM. Pool is free RAM, offload `cpu`, InheritEvidence false.
- Vendor AMD appends one original sentence: Windows AMD is not the NVIDIA evidence path; expect a Vulkan or ROCm llama-server, not CUDA; live Pi required.
- `Get-AirlockGpuVendor` may still return NVIDIA when `nvidia-smi` exists. It must not pretend AMD/Intel were probed. Doctor says so when the vendor is unknown.

## Task 3 — Speed formula, not a probe-as-proof

`Get-AirlockSpeedEstimate -FileGb -BandwidthGiBps -Offload` returns `$null` when bandwidth is missing.

Formula, printed on the result: `tok/s ~= bandwidthGiBps * efficiency / fileGiB`. Efficiency is 0.5 for `gpu-all` and 0.15 for `cpu`. Both constants are named in the function.

Named profiles may carry a bandwidth figure. A missing figure stays null. There is no live llama-bench in unit tests and no upload.

## Task 4 — Doctor file and the two-line pick

`Format-AirlockHardwareDoctor` returns the text that would be logged: each GPU, the chosen GPU, RAM, pick, fit, context, run mode (`gpu` or `cpu`), speed line, and `certificate: candidate` or `certificate: evidence-quant`.

`Format-AirlockPickLine` returns two lines:

```
hardware    <name>    <free> GB free    <ram> GB RAM
pick        <quant>   <gpu|cpu>    candidate|evidence    ctx <n>    fit <level>
```

`Start-AgentSession` writes the doctor text to `$PlatformDir/logs/hardware-doctor.txt` only after WhatIf has already exited. Detection failure (no GPU list and no RAM) is the doctor body, not a throw.

## Out of scope

Chat Ollama ladder. Pi prompt changes. Merging this spec's fit word into `CodingReady`. A second harness.
