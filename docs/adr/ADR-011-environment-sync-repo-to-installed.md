# ADR-011: Environment sync between repo source and installed copy

## Status
Accepted — implemented in `ai-doctor` and `setup.ps1` (no code changes needed to `setup.ps1` itself; the resync mechanism already existed).

## Context

`ai-start`/`ai-stop`/`ai-doctor` and every other `ai-*` command run from whatever
`profile-helpers.ps1` the user's `$PROFILE` dot-sources — always
`~/.ai-platform\scripts\profile-helpers.ps1`, never the repo. A developer working
directly in a git checkout of this repo (as opposed to installing via `install.ps1`)
edits `scripts/` in the repo, but every `ai-*` command in their existing terminal keeps
running the old installed copy until something re-deploys it.

This was not hypothetical. Verified directly during the Tier 1.5 review session
(2026-08-14): a hash comparison of `scripts/*.ps1` between the repo and the installed
copy found **14 files differing or missing** in the installed copy, including
`Uninstall-AI.ps1` (AIR-H3, PR #6) being entirely absent, and `Stop-AI.ps1` missing the
`ai-claude-on` undo block (AIR-H2, PR #4). Both patches were merged in source and not
live in the shell — a shadow copy holding stale state, silently.

This is the same failure shape as the environment-inheritance incident `ai-doctor`
(AIR-H1) already exists to diagnose: a process (there, a shell; here, the installed
script directory) holds a frozen copy of something that changed upstream, and nothing
tells the user it's stale. AIR-H1 solves it for environment variables inherited from a
parent process. This ADR solves the equivalent problem one layer up — for scripts
inherited from a stale install.

## Decision

**No new resync command.** `setup.ps1` already force-copies `scripts/*.ps1` from the
repo to `~/.ai-platform\scripts\` on every run (`Copy-Item ... -Force`, unconditional,
no version check). Re-running `install.ps1` (which `git pull --ff-only`s
`~/.airlock-src` and re-invokes `setup.ps1`) fully resyncs the installed copy. Verified
directly: a before/after diff across the same 14 files went from 14 differing to 0
after one `setup.ps1` run. The gap was never a missing mechanism — it was that nobody
had a way to *know* a resync was needed, or was told to run one.

**`ai-doctor` gets a new check**, added to the existing dead-redirect/orphan/hook checks
it already runs: when `~/.airlock-src` exists (the standard installer's clone target —
see AIR-H16 / ADR-011's sibling fix in `Uninstall-AI.ps1`), it content-hashes every
`scripts/*.ps1` there against the corresponding file in `~/.ai-platform\scripts\` and
reports any that differ, with the fix (`cd ~\.airlock-src; git pull --ff-only;
.\install.ps1`).

- **Content is normalized before hashing** (`\r\n` → `\n`). A fresh `git clone` applies
  the checkout's `core.autocrlf` line-ending conversion; this repo has no
  `.gitattributes`, so byte-identical source can hash differently purely from CRLF vs LF
  depending on when each copy was checked out. Verified: the first version of this check
  (raw `Get-FileHash`) false-flagged `Invoke-CommitReview.ps1` as skewed against a
  freshly-cloned `~/.airlock-src` — `diff` showed identical content, `file` showed one
  copy had `CRLF line terminators` and the other didn't. Normalizing before hashing
  removed the false positive while still catching a real skew (an uncommitted local edit
  to `profile-helpers.ps1`, correctly flagged in both the pre- and post-fix runs).
- **Skipped, not guessed, when `~/.airlock-src` doesn't exist.** A developer working from
  an arbitrary repo checkout elsewhere has no fixed comparison point `ai-doctor` can
  assume — same honesty pattern the function already uses for project-local
  `.claude/settings*.json` (`$projectFound`).
- **No new state file, no version stamp.** The comparison is direct content hashing
  against the installer's own known clone location; nothing new needs to be written at
  deploy time.

**Rejected: a dedicated `ai-resync` command.** Would duplicate `install.ps1`'s existing
`git pull` + `setup.ps1` sequence under a new name for no behavioral difference.

**Rejected: version-stamping the installed copy** (e.g. writing the source commit hash
to a file at deploy time and comparing that). Direct content hashing against
`~/.airlock-src` needs no new state and can't drift out of sync with itself the way a
stamped value could if `setup.ps1` and the stamp write ever diverged.

## Consequences

**Positive**
- `ai-doctor` now answers "is what merged actually running in my shell?" directly,
  closing exactly the gap the Tier 1 backlog review flagged: "treat every 'merged'
  status as 'merged in source, not yet confirmed live' until checked."
- Fix is a one-line pointer to an existing, already-safe command (`install.ps1`
  overwrites scripts unconditionally but never touches user-filled config templates
  without `-Force` — see `setup.ps1`'s own template-skip logic).

**Negative**
- Only covers the standard install path (`~/.airlock-src` → `~/.ai-platform`). A
  developer who deploys some other way (manual copy, symlink) gets no skew detection —
  acceptable, since `ai-doctor` already declines to guess about setups it can't observe.
- Adds one more filesystem walk + hash pass to `ai-doctor`'s runtime, gated behind a
  single `Test-Path` so it's a no-op when `~/.airlock-src` isn't present.
