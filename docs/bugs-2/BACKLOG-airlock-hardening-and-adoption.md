# Airlock: hardening & adoption backlog

Derived from a full-clone review of `main` (119 commits) on 2026-08-14. Every item below was verified against the actual code, not the rendered README — several things I expected to find missing were already implemented, and those are recorded in ADR-008 rather than here.

Prefix `AIR-H` = hardening (rock solid), `AIR-A` = adoption (appealing). Effort is rough: **S** ≤ half a day, **M** ≤ two days, **L** ≥ three days.

---

## Tier 1 — Do first

These are the highest ratio of value to effort. AIR-H1 is the one that would have saved four days last week.

| ID | Item | Effort | Why now |
|---|---|---|---|
| **AIR-H1** | `ai-doctor`: inheritance diagnosis (ADR-008 D1) | M | The only failure mode in this class the tool currently mis-advises on. Clean registry + dirty process + dead port must resolve to "sign out or reboot", with the carrier process named. |
| **AIR-H2** | `ANTHROPIC_API_KEY` → `ANTHROPIC_AUTH_TOKEN` in `ai-claude-on` | S | Live bug. A previously-declined custom API key is ignored silently with no prompt; auth tokens take precedence immediately. One-line change, removes an undiagnosable failure. |
| **AIR-A1** | Deploy the 3D visualizer to GitHub Pages (ADR-010 D4) | S | The best asset in the repo currently requires `git clone` + a local HTTP server. It's a static single file with CDN imports — this is a workflow file and a README link. |
| **AIR-A2** | Move `brag.mp4` (5.5 MB) and the 2.7 MB mp3 out of git; replace the README demo with an animated GIF/WebP | S | 8.2 MB of a 12 MB repo is a video GitHub refuses to play inline — the README says so itself. Attach to a release; clone time drops ~70%. |
| **AIR-H3** | `ai-uninstall` with `-WhatIf` + stale-process notice (ADR-008 D4) | M | No reverse for an `irm \| iex` installer currently exists. Cautious evaluators check for this before installing. |
| **AIR-A3** | Cut `v0.1.0`, tag it, write release notes from `CHANGELOG.md` | S | Zero releases today. The one-line installer should pin a tag, not track `main`. |

---

## Tier 2 — Hardening

| ID | Item | Effort | Detail |
|---|---|---|---|
| **AIR-H4** | CI invariant guard | S | Fail the build on: any `SetEnvironmentVariable(..., 'User'\|'Machine')` or `setx` outside `ai-uninstall`; any airlock-authored write of `ANTHROPIC_BASE_URL` into a `settings.json` `env` block. Both are ADR-008 hard constraints currently enforced only by discipline. |
| **AIR-H6** | Add PSScriptAnalyzer to CI | S | 3,136 lines of PowerShell with syntax-only checking. `profile-helpers.ps1` alone is 861 lines. |
| **AIR-H7** | Provenance variables (ADR-008 D2) | S | `AIRLOCK_INJECTED`/`ENDPOINT`/`INJECTED_AT`/`VERSION`, so `ai-doctor` can label foreign redirects as foreign. The 4-day incident's culprit was a third-party tool. |
| **AIR-H8** | `ai-doctor`: scan `.claude/settings*.json` `hooks` blocks (ADR-008 D3) | S | A `SessionStart` selfheal hook re-applied the bad variable after every fix. The files are already parsed for `env`; read `hooks` too. |
| **AIR-H9** | Installer integrity | M | `install.ps1` is `irm \| iex` with no pinned ref, checksum, or signature. Pin to a tag, publish a SHA-256 in the README, and document the clone-and-inspect path *above* the one-liner rather than below it. |
| **AIR-H10** | Refresh stale model strings in config | S | `provider-policy.json` defaults name `claude-3-5-sonnet-latest`. Invalid/aged model strings are exactly the class of bug that produced a `claude-sonnet-5` failure in a recent session. Add a CI check that validates model IDs against a known list. |
| **AIR-H11** | Split `profile-helpers.ps1` (861 lines, 30+ global functions) into a proper module | L | A `.psm1` with `Export-ModuleMember` gives real `Get-Help`, testability, and removes the dead commented-out help block at lines 838-861 — help text that currently ships as comments and is never shown. |
| **AIR-H12** | Pester tests for `ai-claude-on`/`off`/`doctor` | M | `Test-ClaudeToggle.ps1` covers the stash/restore resolvers. Add cases for: dead-port refusal, foreign-value detection, inherited-orphan classification, profile switching. |

---

## Tier 3 — Adoption

| ID | Item | Effort | Detail |
|---|---|---|---|
| **AIR-A4** | Resolve the naming split | S | Repo is `airlock`, install dir is `~/.ai-platform`, commands are `ai-*`, docs say "the platform". Pick one and migrate with a compatibility shim. Three names for one product is a discoverability tax. |
| **AIR-A5** | Set GitHub topics | S | None set. `ollama`, `local-llm`, `claude-code`, `powershell`, `windows`, `vllm`, `ai-security`. Free discovery for a 0-star repo. |
| **AIR-A6** | `SECURITY.md`, `CONTRIBUTING.md`, issue/PR templates, Dependabot | S | None present. A repo whose pitch is "hardened" and "audit-logged" with no `SECURITY.md` undercuts itself. |
| **AIR-A7** | Onboarding scene + narration track (ADR-010 D2/D3) | M | `airlock-first-run.json` narrating what `ai-start` does. This is the answer to "make the docs fun for beginners" — the renderer already exists. |
| **AIR-A8** | Publish `scenes/schema.json` + `Test-Scene.ps1` + scene-author skill (ADR-010 D1/D5) | M | Converts "build me animated docs" from an unbounded creative task into a validated one Claude Code can actually close the loop on. |
| **AIR-A9** | Sub-60-second quickstart at the top of the README | S | Current README is thorough but the first runnable command sits far down the page. Lead with: install → `ai-start` → `ai-claude-on` → done, then link the depth. |
| **AIR-A10** | Multi-provider profiles (ADR-009) | M | `ai-claude-on -Profile openrouter\|local\|ollama-cloud\|anthropic`. Turns "local or nothing" into the workflow people actually want. |
| **AIR-A11** | Document the honest limits of local Claude Code | S | No prompt caching and ignored `tool_choice` on Ollama's compat layer; OpenRouter guarantees Claude Code only against Anthropic first-party models; ≥32K context recommended, which competes with the ADR-005 VRAM ceiling. Publishing these as expected behaviour builds more trust than omitting them. |
| **AIR-A12** | WSL/Linux support investigation | L | Windows/PowerShell-only is the hard ceiling on adoption. Scope only — decide whether the answer is a real port, a WSL guide, or an explicit "Windows-first by design" statement in the README. Any of the three beats silence. |

---

## Known-good — do not "fix"

Recorded because a future reviewer (human or agent) will otherwise flag these as gaps:

- **`ai-claude-on` injects into the current shell rather than spawning a wrapped child.** Deliberate; see ADR-008's non-decision section.
- **`ai-claude-on` refuses non-Ollama backends.** Correct — vLLM has no Messages API. See ADR-009.
- **`ai-code -Model` validation already exists** (validated against `ollama list`). An earlier session note claiming the flag was silently discarded is out of date.
- **The README already warns about the `settings.json` `env` block trap**, including the exact `Connection refused` wording. It is accurate and should not be softened.
- **The Python tests already run in CI.** `ci.yml` has a second `memory-service-tests` job on ubuntu that installs requirements and runs `pytest tests/ -v`. An earlier draft of this backlog claimed otherwise; that was a truncated read of the file.
- **`scripts/Test-*.ps1` is auto-discovered by CI.** Any new validator named to that pattern is wired in with no workflow change — this is how `Test-Scene.ps1` runs.
- **`provider-policy.json` (intent) and `active-provider.json` (live truth) are deliberately separate.** Documented in the README's data model section; do not merge them.
