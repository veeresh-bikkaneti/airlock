# ADR-002: Auto-install Ollama via winget when missing, no interactive prompt

## Status
Accepted

## Context
[`06-Model-Acquisition-Backlog.md`](../06-Model-Acquisition-Backlog.md) and the double-click launchers (`Start-AI.bat`/`Stop-AI.bat`, added after user feedback that the prior "open pwsh and run a command" flow wasn't actually plug-and-play) closed every gap except one: `scripts/Start-AI.ps1` still assumes Ollama itself is already installed. If it isn't, the script fails with an error and a link to manual install docs — a real interruption to a "double-click and it just works" requirement.

Two existing decisions bear on how to close this gap:
- ADR-001 established model acquisition (discovery, sizing, selection, pull) as a **synchronous pre-flight sequence with no per-step confirmation prompt** — audit logging is the platform's visibility mechanism, not interactive gates. A multi-gigabyte model is already downloaded automatically today without asking first.
- [`01-Local-AI-Platform-Blueprint.md`](../01-Local-AI-Platform-Blueprint.md)'s design principle #4 says "human approval required before risky actions" — installing software is a plausible candidate for that gate.

These two pull in different directions. This ADR resolves the tension for Ollama installation specifically.

## Decision
`Start-AI.ps1` auto-installs Ollama via `winget` when it isn't found, with **no interactive prompt**, immediately after the PowerShell-version check and before any port/process logic runs:

1. Resolve Ollama: try `Get-Command ollama` (PATH), then the default per-user install path `$env:LOCALAPPDATA\Programs\Ollama\ollama.exe`.
2. If found via the fallback path but not on PATH, prepend its directory to `$env:Path` **for the current process** — this is what makes `& ollama ...` calls in this script and in background `Start-Job` scriptblocks (which inherit the parent process's env, not the registry) work without a shell restart.
3. If not found at all:
   - No `winget` available → `Write-AuditLog FAILED`, print the manual-install link (https://ollama.com/download), exit 1. No silent failure.
   - `winget` available → print a clear "Ollama not found — installing via winget" message, `Write-AuditLog STARTED`, run `winget install --id Ollama.Ollama -e --silent --accept-package-agreements --accept-source-agreements`, then re-resolve via step 1-2. Success or failure both go through `Write-AuditLog` and a plain-language console message, matching the existing logging convention.
4. New opt-out switch `-NoAutoInstallOllama` on `Start-AI.ps1` skips all of this and falls straight to today's error-and-exit behavior, for anyone who wants to manage Ollama installs themselves (e.g. locked-down/managed machines where `winget install` would fail or is policy-restricted anyway).

This follows the ADR-001 precedent directly: transparency via audit log + console message, not a confirmation prompt, because a confirmation prompt defeats the double-click requirement this whole change exists for.

## Consequences

**Positive**
- Closes the last manual step in the "double-click `Start-AI.bat`" flow described in [`07-Quickstart-Playbook.md`](../07-Quickstart-Playbook.md).
- Consistent with how model pulls already work: automatic, logged, not gated behind a prompt.
- `-NoAutoInstallOllama` preserves an explicit off switch for managed/locked-down environments.

**Negative**
- `winget install` can take a while on first run (package cache, MSI install) with the console showing no progress from our side during that window — only winget's own output. Acceptable since the same is already true of large model downloads.
- Depends on `winget` being present. Built into Windows 11 by default (App Installer) and most updated Windows 10 installs; genuinely absent only on older/stripped-down images, which is exactly the case step 3's "no winget" branch degrades to today's manual-install message for.
- A machine-wide software install is now something the script can trigger without a per-run prompt. Mitigated by: `winget` itself still shows its own license/progress output in the same console window (nothing hidden), the action is fully audit-logged, and `-NoAutoInstallOllama` opts out.

## Alternatives considered
- **Prompt for confirmation before installing.** Rejected: directly contradicts the "click and it runs" requirement that motivated this ADR; also inconsistent with the no-prompt precedent already set for model downloads in ADR-001.
- **Bundle an Ollama installer in the repo and run it directly.** Rejected: means manually tracking Ollama version updates in this repo; `winget` already does version resolution and is the standard Windows-native package path.
- **Silently fail into cloud-fallback-only mode if Ollama can't be installed.** Rejected: `01-Local-AI-Platform-Blueprint.md` treats local as the default and cloud as explicit opt-in; silently downgrading that would be a bigger, unrelated behavior change.
