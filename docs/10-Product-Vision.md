# Airlock — Vision, Goal, and Objectives

← [Artifact index](00-Artifact-Index.md)

This is the product north star in one place. The ThinkPad P16 / RTX 5000 Ada 16 GB box is the **evidence host**, not the market. A 3/3 on that laptop is not a certificate for anyone else.

Evidence still wins: [`AGENTS.md`](../AGENTS.md), [`adr/PENDING.md`](adr/PENDING.md), and live contracts beat this file if they disagree.

---

## Vision

- Anyone on any PC can run a **local** AI that actually belongs to them — no cloud default, no “it works on the author’s laptop.”
- One box: inspect the hardware, pull an open-weight model that **fits that box**, and if they want coding, **prove tool-calling here** before we trust it.
- A coding assistant that can think, reason, call tools, loop, write, and **resume where it left off**, sitting next to open agents (Pi first; OpenCode / Codex / dsh only after a real pass).
- Do this **without** pretending a 16 GB card (or a RAM-only tower) is GLM, Grok, or cloud Qwen.

---

## Goal

Ship Airlock as a **hardened, single-instance Windows local AI platform** that:

- sizes **this** machine (VRAM first, RAM mmap if the GPU is too small),
- pulls from Hugging Face / Ollama / the catalogue,
- runs **two doors** (chat vs coding) without mixing them,
- persists memory so work can resume,
- never ships another PC’s 3/3 as a certificate.

---

## Objectives

- **Inspect:** RAM, CPU, GPU / no GPU, free VRAM — on whatever PC they have.
- **Acquire:** pull a fitting open-weight GGUF/tag (HF, Ollama, curated list); detached pulls that survive closing the window; fall back when a pull actually fails.
- **Chat door (`ai-start`):** Ollama or vLLM on port 12345, sized for this PC. Talk. Not bash/read/write loops.
- **Coding door (`ai-agent-start`):** llama-server + Pi. GPU Unsloth if it fits; RAM mmap if it doesn’t; live Pi pass **on this machine**; no inherited ThinkPad cert.
- **Tools that are real:** structured `tool_calls`, not “the model narrated a tool.” Known-failed Ollama loops stay failed.
- **Memory:** optional but real — recall/remember so a session can pick up mid-work; degrade loudly if it’s down.
- **Harnesses:** Pi is the proven coding harness; OpenCode / Codex / dsh stay honest (not fake gates).
- **Safety:** one local backend, loopback, logged, no swarm as the default.
- **Portable, not one-box:** Windows first; Linux later; evidence host ≠ product.
- **Any PC, not one laptop:** a friend’s machine gets probed, sized, pulled, and proven **there**.
- **Reasoning / thinking:** models that can plan (Qwen-class, MoE when it fits) — not a chatbot that only completes a sentence.
- **Coding loops:** read/write/bash, repair, retry — a real agentic loop, not a single tool demo.
- **Papers / long work:** enough context + memory that a write-up or a multi-hour task can continue tomorrow.
- **Self-improve in-repo, not magic AGI:** logs, certificates, fail ledgers, and honest step-downs so the platform gets smarter about *this hardware* over time.
- **Open agents:** first-class with **Pi**; then OpenCode, Codex, dsh — each only after a real pass.
- **MoE when it fits:** sparse models as the quality-per-GB path; dense Unsloth 27B when VRAM/RAM allows; never “just download 671B.”
- **Speed honesty:** GPU-fit = interactive; RAM mmap = slow but real; refuse only when even mmap won’t fit.
- **Two doors stay two doors:** `ai-start` never silently becomes coding; `ai-agent-start` never silently becomes Ollama-with-a-Tools-badge.
- **Resume:** `.ai-context` + memory-service so a coding assistant continues mid-diff, mid-paper, mid-debug.
- **Install once:** `setup.ps1` deploys scripts, adapters, profiles; `ai-doctor` / `ai-health` tell you if 11434, certs, or memory are lying.
- **Windows-hardened:** loopback, one instance, audit log, no cloud keys required for the local path.
- **Linux later:** same job (inspect → pull → prove → remember), different OS — spec exists, not shipped.
- **Evidence over marketing:** `candidateOnly: false` is not a certificate; a live contract on *this* PC is.
- **Hardware probe is the installer:** first run reads the box, then chooses a path — never a hardcoded ThinkPad profile.
- **Acquisition sources:** curated `models.json` first, then Ollama pull, then Hugging Face GGUF; one in-flight pull at a time.
- **Chat ranking (AGENT-001, still open):** among models that **fit**, known-failed agentic loops lose to unproven/pass; that still does **not** make the chat pick coding-ready.
- **Coding default is sized, not famous:** empty `-Profile` → Unsloth ladder for *this* VRAM, else RAM mmap; explicit `-Profile` still means that catalogue row.
- **Quant ladder (ADR-018):** `UD-Q3_K_XL` = 16 GB GPU coding quant; step-downs / IQ2 = candidate or mmap; `UD-Q4_K_XL` waits on ~24 GB **and** a new 3/3.
- **Certificate is the gate:** `active-agent.json` only after a live Pi pass; ~24h TTL; expired cert → `ai-agent-start` again.
- **Pi contract:** 3/3 real tool events on the **current** box; step-downs and CPU mmap never inherit the GPU 3/3.
- **Doctor/health:** warn on rogue Ollama 11434 with Airlock 12345 down, expired coding cert, memory port closed, install drift (including `runtime-adapters`).
- **Operator UX:** `ai-port`, `ai-provider`, `ai-stop`, `ai-switch`, `-WhatIf`, `-DownloadConfirmed`, `-ForceVerify`.
- **Tests that exist:** `pwsh -File scripts/Test-*.ps1`, `pytest memory-service/tests`, `pytest tool-proxy/tests` — no fake npm `build && test`.
- **Quality bar:** structured tools on a repair loop, not a single-call probe, not Ollama’s Tools badge, not `supportsFunctionCalling` in JSON.

---

## Who it’s for

- A developer on **any Windows PC** who wants a local coding agent, not a cloud tab.
- Someone with a **fat RAM box / thin GPU** who still wants tools, not “buy a 4090 first.”
- Someone with a **16 GB NVIDIA** who wants the fast Unsloth + Pi path.
- Operators who need **one instance, loopback, logs** — a lab or locked-down laptop, not multi-tenant SaaS.

---

## What a user can do

- `ai-start` and **chat** with a model that fits this PC.
- `ai-agent-start` and **code** (read, write, bash, loop) after a live proof on this PC.
- Pull weights from **Ollama or Hugging Face** without babysitting a dying background job.
- **Leave and come back:** memory + session snapshot resume the work.
- Point **Pi** (and later other CLIs) at the certified local endpoint, not a guessed port.

---

## Product principles

- **Evidence > README.** If the docs and a live 0/6 disagree, the 0/6 wins.
- **Size the box, don’t copy a celebrity setup.**
- **Two doors.** Chat is not coding. Coding is not “Ollama has a Tools badge.”
- **Fail loud.** Expired cert, rogue 11434, memory down, CPU mmap slow — say it.
- **One agent does the work.** Swarms are opt-in, not the product.
- **Never inherit another machine’s pass.**

---

## Constraints (physics, not a vibe)

- Windows first; Linux is a later port, not a silent promise.
- One local chat backend on **12345**; coding is llama-server — not five stacks at once.
- VRAM is the **fast** ceiling; RAM mmap is the **slow** ceiling; neither is a 671B MoE.
- Open Grok coding weights **don’t exist**; GLM-class dense/MoE often **doesn’t fit**.
- `candidateOnly: false` and `supportsFunctionCalling` are **not** verdicts.

---

## Workstreams

- **Probe:** `Test-ResourceAvailability`, `Get-AirlockFreeVramGiB`, `Get-AirlockGpuTotalGiB`, `Get-AirlockFreeRamGiB`.
- **Size:** chat = VRAM ceiling (ADR-005); coding = Unsloth ladder then RAM mmap.
- **Pull:** `Invoke-DetachedModelPull.ps1` + `model-pull.json`; reuse same model only; refuse a second different pull; persist `FAILED`.
- **Run chat:** Ollama or vLLM on 12345, loopback, `ai-port` / `ai-health`.
- **Run coding:** llama-server `--jinja`, Pi harness, GGUF byte-match for the 3/3 artifact.
- **Prove:** workspace / Pi contract; publish cert only on pass.
- **Remember:** memory-service + coding embeddings; snapshot for other harnesses.
- **Heal:** `ai-doctor` (11434, cert, memory, install drift including `runtime-adapters`).

---

## Commands the user should learn

- `ai-start` / `ai-stop` — chat door.
- `ai-agent-start` — coding door (`-WhatIf`, `-ForceVerify`, `-DownloadConfirmed`, optional `-Profile`).
- `ai-port` / `ai-provider` / `ai-health` / `ai-doctor`.
- `ai-memory-start` / `ai-memory-status`.
- `ai-switch` — changes chat model and **invalidates** the coding cert on purpose.

---

## Config / state that matter

- **Repo:** `config/models.json`, `config/agent-profiles.json`, `scripts/`, `memory-service/`, `tool-proxy/`.
- **Live:** `%USERPROFILE%\.ai-platform\` (scripts copy, state, logs, models, certs) — **not** the git tree.
- **Cert:** `state/active-agent.json`. **Pull:** `state/model-pull.json`. **Chat port:** `.active-port.json`.

---

## Definition of a coding-ready model

- Fits **this** PC (GPU-all **or** labeled CPU mmap).
- llama-server template actually has tool markers (`--jinja`).
- Emits **structured** tool events in a multi-turn loop, not JSON-as-prose.
- Survives a repair loop (not a 3/3 single-call party trick).
- Has a cert bound to digest + runtime + harness + this pass.

---

## Milestones (in order)

1. Any-PC **inspect + size + pull** (chat) — largely there.
2. Any-PC **coding door** (GPU ladder + RAM mmap + live Pi) — landing on `feat/airlock-coding-door-gaps` / now on `main` via [#57](https://github.com/veeresh-bikkaneti/airlock/pull/57).
3. **Memory on by default when the venv exists** — best-effort start; still optional.
4. **Harness #2** only after a real OpenCode/Codex/dsh pass (don’t fake AIR-017).
5. **Residency measurement** (layers all vs spill) — FIT-ADAPTERS-001.
6. **24 GB Q4 profile** only with a new 3/3 — ADR-018 follow-up.
7. **Linux Phase 1** — same loop, different OS.
8. Close **AGENT-001** only when chat ranking cannot be mistaken for coding-ready.

---

## Success looks like

- A stranger runs `setup.ps1` → `ai-agent-start` → sees **SIZED for this machine** → live Pi pass → can code.
- They close the laptop, come back, memory/resume still knows the task.
- An 8 GB VRAM / 32 GB RAM box gets a **slow coding door**, not a lecture.
- A 6 GB RAM box gets a **clear refuse + chat**, not a 13 GB download that thrashes.
- Pull survives closing the parent PowerShell window.
- Failed HF import **falls back** instead of hanging on “pending.”
- `ai-doctor` names 11434 vs 12345, expired cert, memory down, install drift.
- CI: every `scripts/Test-*.ps1` + both pytest trees green.

---

## Explicit backlog still open

- AGENT-001 (chat ≠ coding).
- FIT-ADAPTERS-001 (real residency, not only free-VRAM floor).
- AIR-017 / T087 (OpenCode dump; vLLM agentic = zero).
- ADR-018 Q4 on 24 GB (new 3/3).
- Linux port.
- dsh feasibility.
- Full “self-evolve” (beyond fail ledgers + sizing).
- HF fallback-on-fail (4c): job-death fixed; worker-fail fallback is the remaining half.

---

## Metrics that would mean we shipped

- Cold machine: setup → sized coding session → cert published, **without a human picking a profile**.
- Pull survives closing the parent PowerShell window.
- Failed HF import falls back instead of “pending forever.”
- Resume: second session cites a remembered fact / continues the file.
- `ai-doctor` names 11434 vs 12345, expired cert, memory down, install drift.

---

## Risks we already know

- CPU mmap is **usable and slow**; users will call it “broken” if we don’t label 1–5 tok/s.
- Ollama will keep looking easier and keep **failing tool loops**.
- A 3/3 on one GPU will get copy-pasted as “Airlock is production-ready.”
- OpenCode skill dump (~282K) can wreck a local context window.
- vLLM has **no** agentic verdict here yet.

---

## Out of scope (on purpose)

- Drop-in GLM-5 / Grok / cloud Qwen on every laptop.
- Self-evolving AGI / swarms as the default.
- Retrying `qwen2.5-coder:7b`, `qwen3-coder:30b` 0/6, Devstral, Ornith on Ollama.
- Shipping your ThinkPad certificate as theirs.
- Becoming a Node app, Ruflo product, or default multi-agent mesh.
- Auto-killing the user’s personal Ollama on 11434.
- Making 1-bit / 2-bit Unsloth the **default** coding quant.
- Re-verifying Unsloth on Ollama.
- Claiming MTP, vision, or “self-evolving AGI” as shipped features.

---

## Glossary

| Term | Meaning |
|---|---|
| Door | Chat vs coding entrypoint |
| Size | Pick a model/quant for *this* hardware |
| Mmap / CPU offload | Run the GGUF from RAM/disk, GPU layers = 0, slow |
| 3/3 | Three live tool-loop trials passed |
| Certificate | `active-agent.json` after a pass — admission ticket, not a vibe |
| candidateOnly | Allowed to *try*; not proven |
| Evidence host | The ThinkPad used to learn; not the product |

---

## Related

- [`AGENTS.md`](../AGENTS.md) — operating contract (any coding agent in this repo).
- [`adr/PENDING.md`](adr/PENDING.md) — open index; not a certificate.
- [`07-Quickstart-Playbook.md`](07-Quickstart-Playbook.md) — first run.
- [`08-Agent-CLI-Setup-Guide.md`](08-Agent-CLI-Setup-Guide.md) — harness honesty.
- [`09-Cross-Harness-Session-Resume.md`](09-Cross-Harness-Session-Resume.md) — leave and come back.
