# Cross-Harness Session Resume

Switch between AI coding tools mid-task — Claude Code, Grok CLI, Pi CLI, OpenCode — and pick up where you left off without re-explaining yourself. Each tool below was tested against this repo directly. Where something isn't proven end-to-end (a real model reply, not just config loading), that's stated plainly. The design reasoning lives in [`adr/ADR-004-cross-harness-session-resume.md`](adr/ADR-004-cross-harness-session-resume.md); this doc is just "how to use it."

## Contents

- [How it works](#how-it-works)
- [Claude Code](#claude-code)
- [Grok CLI](#grok-cli)
- [Pi CLI](#pi-cli)
- [OpenCode](#opencode)
- [Google Antigravity — not supported](#google-antigravity--not-supported)
- [The snapshot file](#the-snapshot-file)
- [Security notes](#security-notes)

## How it works

One file per project: `.ai-context/SESSION_STATE.md`, written in the repo root. Claude Code writes it automatically — after every turn, right before context compaction, and when a session ends. Every other tool reads it — nothing else writes it this pass, so there's no risk of two tools racing to update the same file.

The file is plain markdown, not JSON — every consumer here is an LLM, so it reads it directly, no parser needed.

## Claude Code

Fully automatic, no setup required if you're on this machine. The snapshot is written on `Stop` (after every turn), `PreCompact` (right before context compaction, auto or manual), and `SessionEnd` — not just at clean session end, since a hard context-limit cutoff or crash skips `SessionEnd` entirely and would otherwise leave the snapshot stale with no warning. A `SessionStart` hook reads it back and warns if it's more than 2 hours old.

- Write: `~/.claude/hooks/ai-context-sync.py`
- Read: `~/.claude/hooks/ai-context-resume.py`
- Wired in `~/.claude/settings.json` under `hooks.Stop` / `hooks.PreCompact` / `hooks.SessionEnd` / `hooks.SessionStart`
- Hook commands use forward-slash paths (`C:/Users/...`); backslash paths were silently mangled by the hook dispatcher's argument parsing and broke `SessionStart` without any error.

**Verified**: ran all scripts against this repo's real transcript and git state — correct branch, commit, changed-files list, and last-10-turns summary came back; confirmed `Stop`/`PreCompact` payload fields (`transcript_path`, `cwd`, `session_id`) via Claude Code hooks documentation.

## Grok CLI

Two files work together: a rule (always loaded) that tells Grok to check for a snapshot, and a skill (invoked on trigger phrases) that surfaces it.

- `~/.grok/rules/ai-context-resume.md` — auto-loaded project instruction
- `~/.grok/skills/ai-context-resume/SKILL.md` — triggers on "resume", "resume my session", "what was I working on", or `/ai-context-resume`

Check what Grok has actually discovered for a given project:

```
grok inspect
```

Look under "Project Instructions" and "Skills" in the output — `ai-context-resume` should appear in both.

**Verified**: `grok inspect` confirmed real discovery of both files against this repo; the skill's invocation snippet (which just calls the same Python script Claude Code uses) runs clean; the interactive TUI genuinely discovers and fires the rule (`session_start [hooks: 1]` observed live). A full automated conversational round-trip could not be completed: Grok's CLI is TUI-only, with no working one-shot print-and-exit mode (`grok agent stdio` is a full JSON-RPC protocol server, not a simple prompt/response pipe) — two separate attempts to drive it non-interactively produced sessions with no assistant response at all, a structural limitation of the CLI when run outside a real terminal, not a bug in this integration. If you want to see it end-to-end, run `grok` interactively yourself and ask it to resume.

## Pi CLI

Same skill-file pattern as Grok.

- `~/.pi/agent/skills/ai-context-resume/SKILL.md` — triggers on "resume", "pick up where I left off", "continue from last time"

Note: Pi has its own separate `~/.pi/agent/projects-memory/` feature — that's Pi's own per-project memory, keyed inside Pi itself, and doesn't read this file. The skill above is the bridge between the two.

**Verified — full live round-trip, real model**: `pi --print -p "..." --no-session` correctly answered with the exact branch (`main`) and exact commit from the real snapshot file. This is the one harness with complete, model-confirmed proof, not just config/discovery checks.

## OpenCode

A global plugin, not a per-project skill — applies automatically to every project you open, no per-repo setup beyond what's already in this repo.

- `~/.config/opencode/plugins/ai-context-resume/plugin.js` — hooks `experimental.chat.system.transform`, reads the snapshot on every request, computes staleness from the real system clock
- Registered in `~/.config/opencode/opencode.json` (`plugin` array — OpenCode does **not** auto-discover files dropped in `plugins/`, registration is required)
- This repo's `opencode.json` + `.ai-context/RESUME_NOTE.md` carry static resume guidance alongside it (the plugin owns the dynamic snapshot, the note carries the "how to think about it" instructions — kept separate so the same content isn't injected twice)

**Why a plugin instead of just the `instructions` config field**: OpenCode's injected context includes a date, not a time. A prompt-only staleness check can't tell "5 minutes old" from "5 hours old" on the same day — only a plugin with real clock access can.

**Verified — delivery mechanism confirmed by direct instrumentation, not inference**: plugin's own test suite passes; temporary debug logging added directly to the hook (then removed) proved it fires on every request, finds the state file, and injects it (`system array length now: 2`), against a real running `opencode run` process with a real model. What did **not** produce a clean result: asking the model to *self-report* whether it had received instructions — it answered "no" despite the injection being provably present, and separately reached for a hallucinated tool call instead of reading its own context. Both are known LLM quirks (models are unreliable narrators of their own system prompt, and a 7B local model in agentic "build" mode is tool-call-biased) — not evidence the plugin failed. Anyone doubting this should re-run the instrumented version rather than trust a model's self-report.

`experimental.`-prefixed hook — confirmed working on OpenCode 1.17.8, may change across versions.

## Google Antigravity — not supported

Antigravity has no CLI (it's a VS Code-fork GUI app — confirmed via its config directory, which has `extensions`/`Code Cache`, standard VS Code internals). Nothing in this system can hook it at session start. If you're switching to Antigravity, open `.ai-context/SESSION_STATE.md` yourself — it's plain markdown, readable as-is.

## The snapshot file

`.ai-context/SESSION_STATE.md`, canonical fields every writer/reader agrees on:

| Field | Meaning |
|---|---|
| `saved_at` | ISO8601 UTC timestamp |
| `session_id` | Opaque ID from whichever harness wrote it |
| `branch` | Git branch at save time |
| `last_commit` | Short hash + subject |
| `changed_files` | Uncommitted files at save time |
| `conversation_summary` | Last 10 user turns |

## Security notes

- **Gitignored.** `.ai-context/SESSION_STATE.md` can contain conversation content — anything you pasted in the last 10 turns — so it's excluded in `.gitignore`. `RESUME_NOTE.md` and `opencode.json` are static config and stay tracked.
- **Treated as data, not instructions.** Both dynamic injectors (`ai-context-resume.py`, `plugin.js`) prefix the snapshot with an explicit disclaimer: it's logged data from a prior session, not a command to follow. Branch names, commit messages, and file paths in the snapshot come from whatever repo is open — without that framing, a malicious repo could plant instruction-like text that a later session mistakes for trusted memory.
- **Read-only adapters.** Only Claude Code's `ai-context-sync.py` script writes (from `Stop`/`PreCompact`/`SessionEnd`), and its temp filename is suffixed with `session_id` so two sessions on the same repo can't collide on each other's in-flight write. Everything else only reads.

## Test coverage

- `~/.claude/hooks/test_ai_context_hooks.py` — checks against the two Python hooks as real subprocesses (atomic write, per-session tmp-file isolation, the git-status off-by-one regression, non-git-repo/malformed-input/missing-transcript-path handling, staleness boundary, the UTF-8 mojibake regression, disclaimer always present). Run: `python ~/.claude/hooks/test_ai_context_hooks.py`.
- `~/.config/opencode/plugins/ai-context-resume/test.mjs` — plugin injection logic, including the exact hour boundary (1.9h vs 2.1h) that proves real sub-hour clock precision, not date-only granularity. Run: `node ~/.config/opencode/plugins/ai-context-resume/test.mjs`.
