# Airlock Vision, Mission & Goals

## Vision

**Every developer deserves a local AI that works on their hardware, not someone else's.**

Airlock exists because running local AI shouldn't require a PhD in infrastructure. You shouldn't need to know which port Ollama is on, whether your firewall is open, or why your model keeps OOM'ing. The platform handles the complexity so you can focus on building.

## Mission

Build the most reliable, transparent local AI platform for Windows — one that:

1. **Respects your hardware** — Sizes models to *your* VRAM/RAM, not a spec sheet
2. **Earns your trust** — Proves tool-calling works on *your* machine before you use it
3. **Stays out of your way** — Two commands (`ai-start`, `ai-agent-start`). That's it.
4. **Tells the truth** — When something doesn't work, it says so. No hidden failures.

## Goals

### For Users
- **Zero-config startup** — `ai-start` works on any Windows 11 machine with zero manual config
- **Honest capabilities** — If a model can't do agentic coding on your hardware, Airlock won't pretend it can
- **Portable skills** — What you learn on your laptop works on your workstation, your DGX, your cloud VM
- **No vendor lock-in** — Your models, your data, your hardware. Airlock just manages the plumbing.

### For the Platform
- **Single source of truth** — One endpoint (`127.0.0.1:12345/v1`), one config, one audit log
- **Fail closed** — No silent fallbacks, no hidden cloud calls, no surprise bills
- **Observable by default** — Every API call logged, every state change audited
- **Extensible without chaos** — New harnesses, new runtimes, new models — all through the same contract

## What "Done" Looks Like

| Milestone | Status | Notes |
|-----------|--------|-------|
| Chat door (`ai-start`) works on any Windows 11 | ✅ | Single-instance, firewall, auto-model |
| Coding door (`ai-agent-start`) proves tool-calling | ✅ | Hardware-sized Unsloth + live Pi 3/3 |
| Multiple harness support | ✅ | Pi, opencode, aider, openclaw |
| Cross-harness session resume | ✅ | Works across Claude, Grok, Pi, OpenCode |
| Hermes sandboxed agent | ✅ | Containerized, read-only career-ops repo |
| Memory service (RAG + sessions) | ✅ | FastAPI + Chroma + LangGraph |
| vLLM backend option | ✅ | With `--enable-auto-tool-choice` |
| Tool-call proxy | ✅ | Grammar-constrained fallback |

## What's Still Honest

| Gap | Why It's Not Hidden |
|-----|---------------------|
| Ollama tool-calling fails agentic loops | Documented in ADR-012, ADR-014, models.json |
| vLLM tool-calling untested on this hardware | Marked `local-limited` in config, needs GPU |
| Linux port unverified | Spec exists, no Ubuntu test run yet |
| Embedding runtime needs live validation | PENDING-9, implemented but untested |
| Chat door auto-select ignores agentic verdict | ADR-012 AGENT-001, flagged in README |

## Non-Goals

- **Cloud-first** — Airlock is local-first. Cloud is opt-in, gated, audited.
- **Model zoo** — We curate a small, verified set. Not 500 models.
- **GUI dashboard** — CLI first. VS Code extension is a thin wrapper.
- **Multi-user** — Single-user, single-machine. By design.

## Philosophy

> **Complexity belongs in the platform, not in the user's workflow.**

Every design decision in Airlock starts with: *What would make this simpler for the person typing `ai-start`?* If it adds a config file, a manual step, or a "read the docs first" moment, it's probably wrong.

---

*This document is the north star. Every PR should move us closer to it.*