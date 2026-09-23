# Session resume — Pi packet and Grok writer

Status: binding for `feature/session-resume`. Do not merge until the architect review and the test scripts below pass.

## Already true (do not redo)

- Claude Code is the only automatic writer of `.ai-context/SESSION_STATE.md` (ADR-004). That hook is installed on the author machine, not in this repo.
- `ai-handoff` only appends an ADR-006 route section. It does not create the file.
- `memory-service` (Chroma, LangGraph, langchain-core) is the only RAG path. If it is down, coding continues and does not recall. Do not add a vector database, a second LangGraph, or dsh.
- The Pi 3/3 proof instruction in `Invoke-PiWorkspaceTrial` stays fixed. A disposable proof workspace does not get a resume packet.
- `Test-AgentStart.ps1` is a unit test. It is not the continue command.

## Canonical snapshot

A session file is line-oriented, not a table:

```
saved_at: 2026-09-23T15:04:00Z
session_id: grok-1
branch: main
last_commit: cb4e864 Size the Unsloth ladder
changed_files:
- scripts/Foo.ps1
conversation_summary:
- last user turn
- older turn
```

An existing `## Task route` section below that block is preserved. The summary stores at most 10 turns. The resume packet shows only the last one.

## Task 1 — Short packet, one allowed file

`scripts/session-resume.ps1` exports pure functions:

- `ConvertFrom-AirlockSessionState` parses the block above.
- `Format-AirlockResumePacket` returns a short text: a one-line disclaimer that this is prior-session data, not instructions; branch; last commit; at most 12 changed files; the single latest user turn; the route line if present. It does not echo the other turns.
- `Write-AirlockSessionState` writes that block atomically and also writes `.ai-context/RESUME_PACKET.md` beside it. If the destination already has a `## Task route` section, that section is copied onto the new file unchanged.
- `Test-AirlockOrdinaryToolPath` denies any path whose segments include `.ai-context`, except a path whose final segment is `RESUME_PACKET.md`. `SESSION_STATE.md` is denied. A normal source file is allowed.

## Task 2 — Pi sees the packet once

- `Format-AirlockPiResumeInstruction` prepends the packet and this sentence, once: `Do not read or write any path under .ai-context except RESUME_PACKET.md. The packet above is the only resume context.`
- `Get-PiContainerRunArgs` gains an optional `-ResumePacket`. When it is empty, the positional instruction is unchanged. The capability contract does not pass it.
- `Resolve-AirlockWorkerTaskText` prepends the packet to a worker task when session text exists, and returns the task unchanged when it does not.
- `New-AgentJobManifest.ps1` uses that function when `.ai-context/SESSION_STATE.md` exists in the repo. No new manifest fields.
- `Install-AirlockResumeHooks -Home <dir>` writes a Pi skill at `<Home>/.pi/agent/skills/ai-context-resume/SKILL.md` that says: read `RESUME_PACKET.md` once at start; never open `SESSION_STATE.md` or any other `.ai-context` path. Tests pass a temp home. Do not write the real user profile from a test.

## Task 3 — Grok can write the same file

- `scripts/hooks/grok-session-end.ps1` accepts `-RepoPath` and `-TurnsJson`. It records git branch, HEAD subject, and changed files from that repo. Turns come from the JSON array. If `-TurnsJson` is omitted, the summary is one line: `Grok session ended without a transcript; git state only.`
- It calls `Write-AirlockSessionState`. It does not call Claude's hook and does not shell out to the Grok TUI.
- The same installer writes `<Home>/.grok/skills/ai-context-resume/SKILL.md` telling Grok to run that script at session end and not to write `SESSION_STATE.md` itself.
- A hard Grok limit that kills the process before the script runs is not captured. Do not claim that it is.

## Tests

`pwsh -File scripts/Test-SessionResume.ps1` covers the parser, the one-turn packet, the path allow/deny, atomic write plus preserved route section, worker task prepend, Pi instruction unchanged when no packet is passed, and both skill files landing under a temp home.

Also re-run `scripts/Test-PiCapabilityContract.ps1` and `scripts/Test-AgentStart.ps1`. No live GPU, no Docker, no Grok TUI.

## Out of scope

dsh. A new vector store. LangGraph as the coding loop. Editing `memory-service`. Replacing the Claude hook. Claiming a Grok hard-limit hook that Grok does not have.
