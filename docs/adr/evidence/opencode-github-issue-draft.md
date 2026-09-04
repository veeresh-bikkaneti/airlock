# Draft GitHub issue for anomalyco/opencode

**Status: DRAFT ONLY. Not filed. Needs human review before `gh issue create`.**

Target repo: `anomalyco/opencode` (npm package `opencode-ai`), confirmed via `gh repo view anomalyco/opencode`.

---

## Title

`[BUG] --auto mode enumerates every installed skill with no cap/relevance-filtering — system prompt grew to ~282,000 tokens (1,070,549-byte system message), unusable with any context-limited backend`

## Body

### Summary

On a real machine with ~2,800 locally-installed skills across the discovered skill roots, `opencode`'s `--auto` mode builds a system prompt that enumerates **every** installed skill — full `<name>`/`<description>`/`<location>` block per skill, no cap, no relevance filtering, no lazy-loading. The resulting system message measured **1,070,549 bytes (~282,000 tokens)** in a byte-level capture of the real request sent to the backend. This is roughly **50x** the ~5,564-token first-turn prompt measured for the same 10-tool surface on the same machine three weeks earlier, before the installed-skill catalogue grew. No context-limited backend — local or hosted — can hold a request this size, so `--auto` mode is currently unusable on any machine with a moderately large skill catalogue.

Full evidence, byte counts, and repro steps are documented in our own (private) repo; this issue summarizes the parts relevant to opencode itself — see the "Evidence" section below for the complete numbers.

### Environment

- opencode: real global config, real `--auto` invocation, nothing stripped or simplified.
- Backend: local `llama-server` (llama.cpp `b10689-57291f264`), OpenAI-compatible `/v1` endpoint, 8192-token context window configured for the model under test — but the finding is backend-agnostic; a 282K-token system prompt exceeds essentially every commonly-deployed context window, local or hosted.
- Skill roots discovered on this machine:
  - `~/.claude/skills/_awesome-skills/*` → 891 subdirectories
  - `~/.agents/skills/*` → 1,936 subdirectories
  - `~/.claude/skills/*` (top-level) → 146 subdirectories
  - ~2,800 total skill directories across roots.

### Repro

1. Have a machine with a few thousand skills installed across the roots `opencode` discovers by default (`~/.claude/skills`, `~/.agents/skills`, any configured skill marketplace directories).
2. Run any `opencode run ... --auto` invocation with a tool-declaring model.
3. Insert a byte-level logging proxy between `opencode` and the backend (or inspect the request via `--print-logs --log-level DEBUG`), and measure the `system` message length in the first tool-declaring request.

### Evidence

A minimal Node.js logging reverse proxy was inserted between `opencode` and the backend for one manual trial (pure pass-through, no request/response mutation). Captured request body:

```json
{
  "bodyBytes": 1095814,
  "messageCount": 2,
  "toolCount": 10,
  "messageRoles": ["system", "user"],
  "messageLens": [1070549, 170],
  "toolNames": ["bash","edit","glob","grep","read","skill","task","todowrite","webfetch","write"]
}
```

The **system message alone is 1,070,549 bytes (~282K tokens)**; the user message and tool declarations are trivial by comparison (170 bytes for a normal 10-tool schema). The system message's bulk is a full enumeration of every locally-installed skill, one `<skill>` block per skill:

```xml
<skill>
  <name>fidel-api-automation</name>
  <description>Automate Fidel API tasks via Rube MCP (Composio)...</description>
  <location>C:\Users\<user>\.claude\skills\_awesome-skills\composio-skills\fidel-api-automation\SKILL.md</location>
</skill>
<!-- repeated once per installed skill, ~2,800 times -->
```

The word "skill" appears 11,152 times and "MCP" 936 times in the captured ~1MB system message.

### Downstream effect: the compaction retry loop also doesn't recover from this

With the resulting request over the backend's context limit, `opencode`'s own compaction/retry loop entered a state where the reported prompt token count **grew** across retries instead of shrinking:

```
282367 → 282744 → 282783 → 282790 → 282817 → 282799 tokens
```

six times over a 180-second window, each attempt returning the same `ContextOverflowError`, followed by a synthetic "conversation was compacted" turn that didn't actually reduce the underlying context. The loop never converged and the model was never sent a request small enough for the backend to accept. We are not certain this is the identical mechanism behind #27924 / #15533 (see "Related issues" below) — flagging it here as an observed symptom, not a root-cause claim, since it's plausible this is simply "compaction cannot make a 282K-token system prompt fit under any circumstances" rather than a compaction-loop bug per se. Worth a maintainer's read either way.

### Comparison point

The same 10-tool surface, same machine, measured **5,564 tokens** for the equivalent first-turn prompt on 2026-08-23 (documented in our own `docs/adr/adr012-p0-pipeline-status.md`). The system prompt has grown roughly **50x** since then — driven entirely by skill-catalogue growth on this machine, not by anything in the specific task or model under test.

### Proposed fix direction

Not attempting to prescribe the exact implementation, but in order of preference:

1. **Lazy-load / relevance-filter skills into the prompt**, the way `packages/opencode/src/tool/skill.ts`'s `verbose: false` path already does for the tool description (per #39294's own description of that code path) — send only `name` + short `description` for skills, and load full skill content on-demand via the `skill` tool call, the same pattern Claude Code's skill system and (per our own side investigation) DeepSeek's `dsh` harness both already use. This is the structural fix; everything else is a stopgap.
2. **At minimum, a hard token budget for the skill-enumeration block**, with a warning printed when skills are truncated/dropped from the prompt, so users get a working (if incomplete) prompt instead of a silently-oversized one that fails opaquely on every context-limited backend.
3. Regardless of (1)/(2): the compaction loop should have some circuit breaker so that a prompt which cannot be brought under budget by compaction fails fast with a clear "system prompt exceeds context, N skills omitted, see --auto skill list size" error instead of retrying 6 times against an unwinnable request.

### Related issues (checked before filing)

- **#39294** ("Remove or truncate `<location>` path in system prompt `available_skills` — wastes ~3.3K tokens/turn") is the closest existing issue, but it's narrower than what we're reporting: it trims one field (`<location>`) from each `<skill>` block, saving ~3.3K tokens on an 84-skill sample. That's real and worth doing, but it doesn't address the underlying no-cap, no-lazy-load enumeration — even with `<location>` stripped, a ~2,800-skill catalogue like ours would still produce a system prompt in the hundreds of thousands of tokens, just ~15% smaller. #39294's own body cites #13188 ("Lazy-load agent/skill lists") as addressing "the broader lazy-loading" problem — we agree that's the right issue to generalize toward, and this report is additional field evidence for prioritizing it at that scope rather than settling for #39294 alone.
- **#27924** ("infinite compaction loop when compression fails to reduce context") and **#15533** ("Auto-compaction infinite loop when assistant ended its turn") describe compaction loops that don't terminate, which is consistent with what we observed (prompt tokens growing across retries instead of shrinking). We can't confirm from the outside whether our case shares their exact trigger condition (#15533's trigger is specifically `finish !== tool-calls`/a naturally-ended turn; #27924's is compaction failing to reduce tokens at all) — ours never got far enough to reach a `finish` state at all, since the *first* turn's request was already over budget. Flagging both as plausibly-related prior art on the retry-loop side of this report, for a maintainer to confirm or rule out.
- **#32202** ("Skill duplicate roots can change `available_skills` across restarts") and **#46327** (symlink dedup warning flood, `~/.claude/skills` → `~/.agents/skills`) describe a different but adjacent problem: duplicate skill roots inflating the effective skill count and destabilizing prompt-cache keys. Our own directory counts (`~/.claude/skills/_awesome-skills/*` → 891, `~/.agents/skills/*` → 1936, `~/.claude/skills/*` top-level → 146) likely include some of this same duplication — `~/.claude/skills` and `~/.agents/skills` are a standard Claude+Codex symlink pair on many machines, matching #46327's exact repro. If #46327's inode-dedup fix lands, our ~2,800-skill count could shrink meaningfully, but the core problem reported here — no cap/lazy-load at all — would still reproduce at whatever the deduplicated count turns out to be, just later.

### Why this matters

Any user who has installed a nontrivial skill marketplace collection (ours: ~2,800 skills, not an exotic setup — accumulated organically from a few marketplace/plugin installs) cannot use `--auto` mode at all, against any backend, local or hosted, once the catalogue crosses a few thousand skills. This isn't a local-model-specific limitation — it would produce the identical oversized request against a hosted frontier-model backend too, just with a higher chance of silently fitting under a very large context window and a correspondingly higher token bill, rather than an outright failure.

---

*Evidence doc this issue summarizes: `docs/adr/evidence/ADR-013-unsloth-live-verification.md` on branch `feature/adr-013-unsloth-verification` of this repo (private; cite the byte counts/measurements above directly in the filed issue rather than linking, since the source repo isn't public).*
