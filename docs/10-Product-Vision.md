# Airlock — Vision, Goal, and Objectives

← [Artifact index](00-Artifact-Index.md)

Any PC, not one ThinkPad. Evidence still wins: [`AGENTS.md`](../AGENTS.md), [`adr/PENDING.md`](adr/PENDING.md), live contracts.

---

## Vision

- Anyone on any PC can run a **local** AI that belongs to them — no cloud default, no “it only works on the author’s laptop.”
- Inspect **this** machine, pull an open-weight model that **fits this machine**, and if they want coding, **prove tool-calling on this machine** before we trust it.
- A local assistant that can think, reason, code, call tools, loop, write papers, and **resume where it left off**.
- Work with open coding agents (Pi first; OpenCode, Codex, dsh only after a real pass).
- Do this without pretending a 16 GB GPU or a RAM-only box is GLM, Grok, or cloud Qwen.

---

## Goal

- Ship a **hardened, single-instance Windows local AI platform** for any PC.
- Size **this** hardware (VRAM first; RAM mmap if the GPU is too small).
- Pull a fitting open-weight model from Hugging Face, Ollama, and the curated catalogue.
- Keep **two doors**: chat (`ai-start`) vs coding (`ai-agent-start`) — never mix them.
- Persist memory so a model and a coding assistant can continue mid-work.
- Never ship another PC’s 3/3 as a certificate.

---

## Objectives

- **Inspect** RAM, CPU, GPU / no GPU, and free VRAM on whatever PC they have.
- **Acquire** a fitting GGUF or Ollama tag; detached pulls that survive closing the window; fall back when a pull actually fails.
- **Chat door (`ai-start`):** Ollama or vLLM on port 12345, sized for this PC. Talk. Not bash/read/write loops.
- **Coding door (`ai-agent-start`):** llama-server + Pi. GPU Unsloth if it fits; RAM mmap if it doesn’t; live Pi pass **here**; no inherited ThinkPad cert.
- **Empty `-Profile` sizes this box;** explicit `-Profile` still means that catalogue row (never “whatever is already installed”).
- **Quant ladder:** `UD-Q3_K_XL` for 16 GB-class GPU; step-downs for smaller VRAM; CPU mmap when RAM can hold the GGUF; refuse only when even mmap won’t fit.
- **Structured tools** in a real repair loop — not JSON-as-prose, not Ollama’s Tools badge, not `supportsFunctionCalling` as a verdict.
- **Known-failed Ollama loops stay failed** (`qwen2.5-coder:7b`, `qwen3-coder:30b` 0/6, Devstral, Ornith). Do not retry them as the coding default.
- **Memory** so sessions resume (recall + remember); if it’s down, say so and passthrough — no silent amnesia.
- **Cross-harness resume** via `.ai-context` so Pi / Grok / OpenCode can pick up a snapshot.
- **Harness honesty:** Pi is the proven coding harness; OpenCode is not a verified gate; Codex is connectivity; dsh is wait.
- **Certificate gate:** publish `active-agent.json` only after a live pass; ~24h TTL; step-downs and CPU mmap never inherit a GPU 3/3.
- **Doctor/health:** name rogue Ollama on 11434, Airlock 12345 down, expired cert, memory down, install drift (including runtime adapters).
- **Safety:** loopback, one instance, audit log, no secrets in the tree, no swarm as the default.
- **Install once:** `setup.ps1` deploys scripts, adapters, and profiles to `~\.ai-platform\`.
- **Tests that exist:** `scripts/Test-*.ps1`, `pytest memory-service/tests`, `pytest tool-proxy/tests`.
- **Windows first;** Linux later (same inspect → pull → prove → remember loop).
- **MoE when it fits** (quality per GB); dense Unsloth 27B when VRAM/RAM allows; never “just download 671B.”
- **Speed honesty:** GPU-fit = interactive; RAM mmap = slow (often 1–5 tok/s) but real.
- **Evidence over marketing:** `candidateOnly: false` is not a certificate.
- **Out of scope:** drop-in GLM/Grok replacement, self-evolving AGI, swarms as default, inheriting another machine’s pass.

---

## Related

- [`AGENTS.md`](../AGENTS.md) — operating contract.
- [`adr/PENDING.md`](adr/PENDING.md) — open index (not a certificate).
- [`07-Quickstart-Playbook.md`](07-Quickstart-Playbook.md) — first run.
- [`08-Agent-CLI-Setup-Guide.md`](08-Agent-CLI-Setup-Guide.md) — harness setup.
- [`09-Cross-Harness-Session-Resume.md`](09-Cross-Harness-Session-Resume.md) — leave and come back.
