# Local AI Platform Artifact Index

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
