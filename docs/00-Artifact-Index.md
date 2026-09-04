# Airlock Artifact Index

## Purpose
This artifact bundle defines a **local-first** AI platform for Windows 11 with PowerShell 7, strong security defaults, auditable workflows, and optional cloud fallback only when the user provides an API key.

## Included Artifacts
- `01-Local-AI-Platform-Blueprint.md` — architecture, operating model, provider strategy, and controls.
- `02-Windows-Implementation-Guide.md` — step-by-step setup guide with commands and validation steps.
- `03-PowerShell-Module-Spec.md` — reusable function design for start/stop/provider selection/logging.
- `04-Security-Audit-Runbook.md` — audit trails, secret handling, approval gates, and hardening checklist.
- `05-Provider-Fallback-Matrix.md` — local-first routing rules and cloud provider fallback behavior.
- `06-Model-Acquisition-Backlog.md` — backlog for automatic model discovery, hardware-aware selection, and background pull/run.
- `07-Quickstart-Playbook.md` — beginner-friendly usage guide: run `Start-AI.ps1`, no manual Ollama/model setup needed.
- `08-Agent-CLI-Setup-Guide.md` — beginner-friendly, tested step-by-step setup for every agent CLI (Pi.dev, opencode, jcode, Codex, Claude Code, aider, Copilot CLI, Gemini CLI).
- `COMPONENTS.md` — beginner-friendly component overview: what each file/folder does and why it exists.
- [`tools/airlock-manual/index.html`](../tools/airlock-manual/index.html) — interactive, illustrated user manual: plain-English definitions, an animated architecture diagram, every command with a snippet and a real use case, and a deep dive into the memory service's RAG pipeline (decision-flow diagrams, a swimlane, and an ER diagram). Open the file directly in a browser — no build step, no server.
- [`adr/PENDING.md`](adr/PENDING.md) — leftover work after AIR-014/015/016 on `main` (live ThinkPad run, AGENT-001, AIR-017).
- [`adr/ADR-018-unsloth-quantization-strategy.md`](adr/ADR-018-unsloth-quantization-strategy.md) — Unsloth Dynamic 3.0 quant ladder vs the 16 GB Ada card.

## Design Principles
1. Local AI first; cloud only by explicit opt-in.
2. All secrets stored outside source code.
3. Every step logged with timestamps and outcome state.
4. Human approval required before risky actions.
5. Provider abstraction so models can be swapped without rewriting workflows.

## Suggested Use Order
1. Read the blueprint.
2. Follow the implementation guide.
3. Implement the PowerShell module.
4. Apply the security runbook.
5. Validate fallback behavior with the provider matrix.
