# Resuming this project

If `SESSION_STATE.md` in this same directory is present, it's a snapshot
another AI harness (Claude Code, Pi, Grok CLI) left when a previous session
ended — branch, uncommitted files, and a summary of the last conversation
turns.

- Check its `- Saved:` timestamp. If it's more than 2 hours old, tell the
  user this is a stale snapshot and confirm before acting on it — the repo
  has probably moved on.
- Summarize where the previous session left off in two or three sentences,
  then ask what to continue with. Don't silently resume the old task.
- Git is the authority on what's actually true now; if the snapshot and
  `git status`/branch disagree, trust git.
- If `SESSION_STATE.md` isn't present, there's nothing to resume — ignore
  this note entirely.
