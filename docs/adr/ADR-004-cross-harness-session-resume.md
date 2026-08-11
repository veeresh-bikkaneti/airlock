# ADR-004: Cross-harness session resume via project-local `.ai-context/SESSION_STATE.md`

## Status
Accepted (Phase 1 implemented; Phase 2 in progress)

## Context
User switches between AI coding harnesses on the same project when hitting a token/context limit: Claude Code (local CLI and cloud-subscription — same binary, one integration surface), Google Antigravity, Grok CLI, OpenCode, and Pi CLI. Needed a way to resume mid-task in whichever harness comes next, without manually re-explaining state each time.

An initial AI-generated spec proposed a custom Python daemon, a systemd user service, and a global `~/ai-vaults/` vault. Verified against this machine and found wrong on multiple points:
- No systemd on Windows — `ruflo daemon install-supervisor` itself only targets launchd (macOS) / systemd-user (Linux); Windows would need `schtasks`.
- `ruflo memory save --vault ... --context-file ...` is not a real CLI surface. Real ones are `ruflo session save` and `ruflo hooks session-end --save-state`.
- `~/.claude/sessions/*.json` exists but holds `pid`/`cwd`/`status`, not token counts.
- `ruflo daemon` (Node.js background worker system) already runs on this machine (confirmed via `ruflo daemon status`: PID active, 7 workers) — a second custom daemon would duplicate it.
- Of the 5 target harnesses, `kimi` (from the original spec) isn't installed; the real set is Claude Code, Grok CLI, OpenCode, Pi CLI (all installed, confirmed via `command -v`), and Antigravity (GUI app, no CLI).

## Decision

1. **Project-local state, not a global vault.** One `.ai-context/SESSION_STATE.md` per repo. Every harness in play is workspace/cwd-based (Claude Code, OpenCode, Antigravity, Grok CLI, Pi all open a project folder) — a file inside the repo is visible to all of them with zero external path configuration, and travels with git.

2. **Plain markdown, not JSON.** Every consumer of this file is an LLM, so no parser is needed — adapters just surface file content into context. Canonical fields: `saved_at` (ISO8601 UTC), `session_id`, `branch`, `last_commit`, `changed_files[]`, `conversation_summary[]` (last 10 user turns). Harness-specific detail may be appended below the canonical block but must not reorder/remove it.

3. **Single writer.** Only Claude Code's `SessionEnd` hook writes the file (atomic: temp file + rename). All other harness integrations are read-only adapters — avoids concurrent-write races, no file locking required. Writing from additional harnesses is out of scope for this pass; revisit if a concrete need shows up.

4. **Claude Code integration (Phase 1, done):**
   - `SessionEnd` hook — `~/.claude/hooks/ai-context-sync.py` — gathers git branch/status/last-commit and the last 10 user turns from the session transcript (`transcript_path` from the hook's stdin JSON payload), writes atomically to `<project>/.ai-context/SESSION_STATE.md`.
   - `SessionStart` hook — `~/.claude/hooks/ai-context-resume.py` — reads the file if present, warns if `saved_at` is >2 hours old, prints content into context. Silent no-op if the file doesn't exist.
   - Both wired into `~/.claude/settings.json` (`hooks.SessionEnd` / `hooks.SessionStart`), appended alongside the pre-existing Calorieschart-specific `SessionEnd` hook without modifying it.
   - Tested against this repo's real transcript and git state before wiring.

5. **OpenCode / Pi CLI / Grok CLI integrations (Phase 2):** read-only adapters built per-tool, each verifying that tool's actual convention (existing skill/config file formats, real auto-trigger mechanisms) before writing anything, rather than assuming a shared mechanism across tools.

   OpenCode specifically: the first pass used the `instructions` config field alone (static file inclusion, confirmed real via schema). That's insufficient on its own — OpenCode's injected system context includes only a date string, not a time, so a prompt-only staleness check can't distinguish "5 minutes old" from "5 hours old" on the same day. Superseded by a plugin (`~/.config/opencode/plugins/ai-context-resume/plugin.js`, registered globally in `~/.config/opencode/opencode.json`) hooking `experimental.chat.system.transform`, which reads the state file and computes age from the real system clock on every request. `instructions` still carries the static `RESUME_NOTE.md` guidance; the plugin owns the dynamic snapshot + staleness math (avoids double-injecting the same content two different ways). Verified: plugin's own `test.mjs` passes, code inspected directly. Global registration is actually the right shape here — the plugin is project-agnostic (reads `<worktree>/.ai-context/SESSION_STATE.md` relative to wherever it runs), so it applies to every project automatically without per-repo `opencode.json` copies. `experimental.`-prefixed hook, confirmed working on OpenCode 1.17.8, may not survive version upgrades unchanged.

6. **Antigravity: accepted limitation, not solved.** Confirmed to be a VS Code-fork GUI app (its config dir contains `extensions`, `Code Cache` — no CLI on PATH). Cannot be hooked at session start. Best case is it reads `.ai-context/SESSION_STATE.md` if the user points it at the file directly; no auto-trigger is possible with current tooling.

## Consequences

**Positive**
- Zero external state to keep in sync — the handoff file lives with the code it describes.
- No new daemon, no new supervisor process, no OS-specific service unit — reuses hooks Claude Code already runs natively.
- Format survives even where auto-trigger isn't possible (Antigravity): a human can open and read the file directly.

**Negative**
- State is per-repo, not a single cross-project view — resuming "everything I was doing across all projects" isn't covered, only one repo at a time.
- Auto-trigger-on-start is confirmed only for Claude Code; OpenCode/Pi/Grok CLI adapters may land as manual-invoke depending on what Phase 2 actually confirms about each tool's real capabilities.
- Antigravity has no working auto-resume path at all under this design.
