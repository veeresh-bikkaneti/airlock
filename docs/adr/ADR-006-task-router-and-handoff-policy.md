# ADR-006: Task router and cloud-limit handoff policy

## Status
Proposed — not yet implemented. Written as the spec a build swarm executes against.

## Context

The platform's actual goal — "keep making progress on a real repository when the cloud model is unavailable, over budget, or overkill" — has no defined shape today. Two gaps, previously tracked separately, are really one feature:

1. **No routing guidance.** Nothing tells a user whether a given task is safe to hand to the local model before they try it and find out. The only evidence available — `models.json`'s `supportsFunctionCalling` flag, and this session's own finding that a 7B model correctly connects but lacks the tool-calling reliability for multi-step agentic work on a large repo — is real but not surfaced as a decision.
2. **No handoff policy** (tracked as AIR-16 in `docs/bugs/airlock-architectural-implementation-plan (1).md`). Cross-harness session resume already exists (ADR-004) — the *mechanism* to hand off context works. What's missing is the *policy*: which task classes should move to local on a cloud limit, and which should wait for cloud to be available again.

Both gaps are answered by the same mechanical check, so this ADR covers both rather than building two half-features that would need to agree with each other anyway.

## Decision

A new function, `Get-TaskRoute` (pure, testable — no I/O), and a thin CLI wrapper `ai-route <description>` in `profile-helpers.ps1`.

**Inputs** (all cheap to compute, no LLM call to decide):
- File count the task touches (from the description, or `-Files <paths>` if the caller knows them).
- Presence of planning/architecture keywords in the description (`refactor`, `migrate`, `design`, `architecture`, `plan` — exact list in `config/task-router-keywords.json`, not hardcoded, so it can be tuned without a code change).
- The active model's `supportsFunctionCalling` value from `models.json`.
- Rough line count of the largest touched file, if known.

**Decision rule** (first matching rule wins, evaluated top to bottom):
1. Active model's `supportsFunctionCalling` is `false` → **cloud**, reason: "active model can't reliably tool-call."
2. Any planning/architecture keyword present → **cloud**, reason: "task needs planning, not just editing."
3. File count > 2, or largest touched file > ~800 lines → **cloud**, reason: "multi-file or large-file scope."
4. Otherwise → **local**, reason: "single-file, scoped, model supports tool calls."

**Output is advisory only.** `ai-route` prints the decision and reason and stops — it does not launch `ai-claude-on`, does not launch aider, does not switch anything. The user still acts on it manually. Auto-routing (the router deciding *and* switching for you) is a deliberate non-goal for this pass — see Alternatives considered.

**Handoff policy (AIR-16), reusing the same rule:** `ai-handoff` (new) captures the current task's route decision alongside the existing ADR-004 session snapshot, so `.ai-context/SESSION_STATE.md` carries not just "what was I doing" but "was this flagged local-safe or cloud-only," making the return-to-cloud path informative instead of a replay.

## Consequences

**Positive**
- Turns a guess ("will the local model handle this?") into a one-line, explainable answer, using signals the platform already has (`models.json`, file count) rather than inventing new ones.
- Advisory-only keeps blast radius small — a wrong routing decision costs a wasted `ai-route` call, not a wrongly-launched session.
- Shares one rule set between "should I go local right now" and "what should the handoff note say," so the two can't silently disagree.

**Negative**
- Heuristic, not learned — a task that's actually fine for local but trips the file-count rule gets routed to cloud unnecessarily (false negative, safe direction). Tuning happens via the keyword/threshold config file, not a model.
- Doesn't read the actual diff or repo structure — a "single file" edit to a 5000-line god-file still passes rule 3's line-count check if the router isn't told the real line count.

**Neutral**
- No new state file beyond appending to what ADR-004 already writes.

## Alternatives considered

- **Auto-routing (router decides and switches automatically).** Rejected for this pass: the router's signals are cheap heuristics, not verified predictions — silently switching a user's active backend based on a heuristic that's sometimes wrong is a worse failure mode than asking them to read one line and decide. Revisit once the advisory version has enough real usage to know its false-positive/negative rate.
- **LLM-based routing (ask a model to classify the task).** Rejected: adds latency and a dependency on the very backend choice it's trying to make, for a decision that's answerable from file count and keywords alone.
- **Fold into `ai-code` directly instead of a separate `ai-route` command.** Rejected: `ai-code` already does real work (validates the model, launches aider); bolting a policy decision onto it conflates "check if this is a good idea" with "do the thing," and makes the router impossible to invoke standalone for planning.

## Links
- Supersedes nothing; extends ADR-004 (cross-harness session resume) with a policy layer on top of its mechanism.
- Source: `docs/bugs/airlock-architectural-implementation-plan (1).md`, AIR-16.
