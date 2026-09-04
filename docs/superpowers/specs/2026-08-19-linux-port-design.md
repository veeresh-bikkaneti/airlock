# Full Linux port — design

Date: 2026-08-19
Status: Proposed — Phase 1 only is in scope for the next implementation plan; Phases 2-5 are roadmap, not yet designed in detail.

## Problem

Airlock's orchestration layer (single-instance enforcement, port
management, firewall guard, CLI, env-injection safety) is Windows/
PowerShell-only. Nothing else in the repo runs on Linux except by
accident: Ollama itself is cross-platform, and the vLLM Docker backend
*can* run on Linux, but there is no script, CLI, or doc that lets a
Linux user actually operate Airlock the way a Windows user does. This
is a real adoption barrier — the repo has a public GitHub remote, and
Windows-only shuts out contributors and users on Linux or macOS.

## Constraints

- **No Linux machine in this environment.** Everything built here is
  unit-tested and code-reviewed, never run against a live Ubuntu box.
  Every doc/PR/commit produced from this spec must say so plainly —
  "unverified on real Ubuntu" is a disclosed limitation, not a claim of
  completeness, matching how `hermes-container/README.md` already
  discloses its own not-yet-live-tested status in this repo.
- **Adoption is the actual driver**, not personal need or architectural
  purity (confirmed with the user during brainstorming) — this favors
  shipping a real, narrower capability fast over a theoretically-complete
  design that ships nothing for months.
- **Ubuntu 22.04/24.04 LTS is the primary target.** Debian-derivatives
  should work by extension since nothing here is Ubuntu-specific, but
  they are not separately tested. No macOS, no AMD/ROCm — both explicitly
  out of scope for this spec.
- **Windows support does not regress.** This is additive. Nothing in
  `scripts/*.ps1` changes behavior for existing Windows users as a side
  effect of this work.
- **Shared core, thin OS shims** (confirmed with the user) — one
  Python implementation of the OS-agnostic logic, not two independently
  maintained native implementations. `tool-proxy/` and `memory-service/`
  are already Python/FastAPI and need no rewrite; this spec extends that
  precedent to the orchestration layer instead of introducing a second
  language/paradigm split.
- **MVP-first sequencing** (confirmed with the user, chosen over
  bottom-up and risk-first alternatives): ship the thinnest real
  end-to-end path first, backfill hardening in later phases, each phase
  independently shippable. A phase that ships with a disclosed gap (no
  firewall enforcement yet) is acceptable; a phase that ships with a
  silent gap is not.

## Roadmap (Phases 2-5, sketch only — not designed in this spec)

| Phase | Delivers |
|---|---|
| 2 | Real network guard — iptables/nftables/ufw (which one is an open question for that phase's own design pass) |
| 3 | Full CLI parity — `ai-doctor`, `ai-claude-on`/`ai-claude-off`, `ai-code`, model auto-selection prompts |
| 4 | Env-injection safety redesign for Linux's actual model (shell rc files and process-tree inheritance, not Windows' registry/`explorer.exe`-ancestor model ADR-008 depends on) |
| 5 | Install/uninstall (`curl \| sh` equivalent of `install.ps1`/`ai-uninstall`) + docs |

Each later phase gets its own brainstorm/spec before implementation,
per the process this spec itself followed. Phase 1 is designed in full
below because it is what gets implemented next.

## Phase 1: shared core + Ollama backend management on Linux

### Decision

Extract the OS-agnostic logic already living inside
`scripts/Start-AI.ps1`/`Stop-AI.ps1`/`profile-helpers.ps1` into a new
Python package, `airlock_core/`, at the repo root (sibling to
`tool-proxy/` and `memory-service/`, same dependency-isolation
pattern — its own `requirements.txt`, no shared venv). Windows keeps
using its existing PowerShell scripts unchanged in this phase — the
extraction targets new Linux code, not a rewrite of the working
Windows path. A future phase may have `profile-helpers.ps1` call into
`airlock_core` too, but that is out of scope here (see "Non-goals").

Two new files ship on top of `airlock_core`:

- `airlock_core/backend.py` — the actual port-scan-and-adopt and
  single-instance logic, in Python, targeting Linux process/socket
  APIs. This is a **new implementation** informed by
  `Start-AI.ps1`'s behavior, not a transpilation — Windows uses
  `Get-NetTCPConnection`/firewall rules; Linux uses `psutil`
  (or equivalent) process/socket inspection and a stub guard (see
  below). The single-instance *guarantee* must match Windows': exactly
  one Ollama process, adopting an already-running instance on the
  known port range rather than always launching a second one.
- `scripts/airlock.sh` — a thin bash CLI exposing `ai-start` and
  `ai-stop` as shell functions (sourced from `.bashrc`/`.zshrc`,
  mirroring how `profile-helpers.ps1` is dot-sourced from `$PROFILE`
  today). Each function shells out to `airlock_core` via
  `python3 -m airlock_core.cli <command>`. No other `ai-*` commands are
  added in this phase — `ai-doctor`, `ai-claude-on`, etc. are Phase 3.

### Firewall status this phase

**Stubbed, not enforced.** `ai-start` on Linux prints a loud, explicit
warning that no inbound-blocking guard exists yet on this platform and
names Phase 2 as where it lands — the same "disclosed gap, not silent
gap" pattern as `hermes-container/README.md`'s live-testing disclosure.
This is a deliberate, stated scope cut for Phase 1, not an oversight —
see Constraints above for why MVP-first accepts it.

### Components

- **`airlock_core/__init__.py`, `airlock_core/backend.py`** (new).
  - `find_active_port(candidates: list[int]) -> int | None` — probes
    each candidate port for a live, responding Ollama instance (same
    `/api/tags` liveness check `Start-AI.ps1` already uses), returns
    the first match or `None`. Mirrors `Start-AI.ps1`'s own candidate
    list and adopt-if-running behavior: try `11434` (Ollama's own
    default, in case it's already running as a background service)
    then `12345`-`12350` (Airlock's own range), same order, same
    "adopt what's already there rather than always launching a second
    instance" rule.
  - `write_audit_log(action, result, ...) -> None` — appends the same
    JSONL shape `Start-AI.ps1`/`Stop-ToolProxy.ps1` already write to
    `~/.ai-platform/logs/<date>.jsonl` (timestamp, user, host, action,
    result, provider, endpoint, message). Structured audit logging is
    a core platform guarantee (README's "After This Platform" table),
    not an optional extra — every function in `backend.py` that starts
    or stops a process calls this, matching the Windows scripts'
    existing behavior line for line rather than treating it as a
    Phase-3-or-later nice-to-have.
  - `start_ollama(port: int) -> subprocess.Popen` — launches
    `ollama serve` bound to the given port if nothing is already
    running there, via `OLLAMA_HOST` env var (Ollama's own documented
    mechanism, cross-platform).
  - `write_active_port_state(port: int, path: Path)` — writes the same
    `.active-port.json` shape `Start-AI.ps1` already writes
    (`{"port": <int>}`), so `tool-proxy`/`memory-service` need zero
    changes to work identically on Linux — they already just read that
    file.
  - `stop_ollama(state_path: Path)` — reads the state file, verifies
    process identity before killing (same PID-reuse concern this
    session already fixed for `Stop-ToolProxy.ps1` — Linux has the
    same PID-recycling risk PROXY-004 addressed on Windows, so this
    gets the fix from day one, not bolted on later).

- **`airlock_core/cli.py`** (new). `python3 -m airlock_core.cli start`
  / `stop` — argument parsing and calling into `backend.py`, printing
  the same kind of user-facing status `Start-AI.ps1`/`Stop-AI.ps1`
  print (endpoint, port, "left alone" model disclosure). `start`
  additionally prints the firewall-gap warning from "Firewall status
  this phase" above, every single run, not just the first — the
  warning must remain impossible to miss for as long as Phase 2 hasn't
  landed, the same way `hermes-container/README.md`'s "Not yet
  live-tested" banner stays up front rather than fading into a
  one-time notice.

- **`scripts/airlock.sh`** (new).
  ```bash
  ai-start() { python3 -m airlock_core.cli start "$@"; }
  ai-stop()  { python3 -m airlock_core.cli stop "$@"; }
  ```
  Installed by a `source ~/.ai-platform/scripts/airlock.sh` line added
  to `.bashrc`/`.zshrc` — mirrors the existing
  `$DotSourceLine`/`$PROFILE` pattern in
  `Uninstall-AI.ps1`/`setup.ps1` closely enough that Phase 5's
  install/uninstall work can extend the same mental model instead of
  inventing a second one.

- **`airlock_core/requirements.txt`** (new) — `psutil` (process
  inspection, cross-platform but only actually exercised on Linux in
  this phase), no web framework needed (no HTTP server in this
  package, unlike `tool-proxy`/`memory-service`).

### Testing

- `airlock_core/tests/` — pytest, mirroring `tool-proxy/tests/`'s
  existing style: `find_active_port`/`start_ollama`/`stop_ollama`
  tested with monkeypatched `subprocess`/socket calls, no real Ollama
  or real Linux required to run the suite (so it can run in this
  Windows session and in Linux CI both). A live-only test class is
  marked and skipped by default (`@pytest.mark.skipif` on `sys.platform
  != "linux"` or missing binary), for a human on real Ubuntu to run
  later — CI does not claim to prove the live path.
- CI: new `airlock-core-tests` job in `.github/workflows/ci.yml`,
  `runs-on: ubuntu-latest` (the repo's other Python jobs already run
  cross-platform-clean; this is the first job that specifically proves
  the package imports and its mocked tests pass on real Linux, even
  though it does not prove a live Ollama round-trip).

### Non-goals (this phase)

- No `ai-doctor`, `ai-claude-on`/`off`, model auto-selection, or any
  other `ai-*` command beyond start/stop.
- No firewall enforcement (stated above).
- No change to any existing Windows script's behavior.
- No vLLM-on-Linux support (Ollama only, confirmed with the user —
  "don't we already have Ollama" was the correction that settled this).
- No macOS.
- `profile-helpers.ps1` is not refactored to call into `airlock_core`
  in this phase — that convergence is a future phase's decision, made
  once the Linux side has real usage to validate the extraction
  against, not before.

## Open questions for Phase 2+ (not blocking Phase 1)

- Which Linux firewall mechanism — `ufw` (simplest, Ubuntu-default),
  `nftables` (modern, more precise), or detect-and-support-both? Needs
  its own spike/spec.
- Does `airlock_core` eventually absorb `profile-helpers.ps1`'s logic
  too (true single shared core), or does Windows keep its own
  PowerShell implementation forever with `airlock_core` as Linux-only?
  Deferred — Phase 1 doesn't need this answered, and answering it
  early risks over-designing against usage that doesn't exist yet.
