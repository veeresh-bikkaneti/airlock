# ADR-007: Retrieval governance for memory-service

## Status
Proposed — not yet implemented. Written as the spec a build swarm executes against.

## Context

`memory-service` (FastAPI + Chroma + LangGraph, added in commit `8332d85`) sits in the request path for every `ai-memory-on` session, injecting retrieved context into every chat turn. This session verified the *mechanism* works — `Test-PullProgress`-style live testing confirmed context retention and per-project recall via a real pytest run (4/4 passing) — but `docs/bugs/airlock-architectural-implementation-plan (1).md`'s Epic E (added the same day, after a coverage audit) names three governance gaps the mechanism doesn't cover:

1. **No freshness tracking.** A stale retrieved chunk — a function signature deleted three commits ago — gets injected as `"Relevant memory: ..."` and the model treats it as authoritative. This is described in that doc as a *manufactured* hallucination: the platform handed the model a confident, wrong fact, rather than the model inventing one.
2. **No relevance/attribution.** Retrieved chunks carry no path, line range, or index-build time, so there's no way for the model — or the user — to tell retrieved material from the model's own priors, or to judge whether a chunk actually answers the query.
3. **Undeclared dependency surface.** `langsmith` (a LangChain telemetry client that can transmit externally) loads as a live transitive dependency — confirmed this session via a real `pytest` run showing it as a loaded plugin — but is unpinned and undocumented. Dormant by default (needs `LANGCHAIN_TRACING_V2=true` plus an API key to actually phone out), but "dormant because nobody's set the env var yet" is not the same guarantee as "disabled by configuration."

## Decision

Four changes, each independently shippable:

1. **Explicit retrieval config.** `config/memory-service.json` (new) declares embedding model, vector store implementation, index path, chunking strategy, `topK`, and similarity threshold — no implicit defaults buried in `memory_store.py`. `MemoryStore.__init__` reads this file instead of hardcoded constructor defaults.

2. **Index freshness tracking.** Every `remember()` call records the commit SHA and UTC timestamp of the repo state it was written against (read via `git rev-parse HEAD` at call time, passed through as `metadata`). `ai-memory-status` reports staleness in commits-behind and hours-since-index, computed by diffing the stored SHA against current `HEAD`.

3. **Attributed retrieval, fail-closed on missing signal.** Every chunk returned by `recall()` carries path, line range (where derivable from metadata), and the freshness fields from (2). Responses built from retrieved context are marked as augmented; if a query returns zero chunks above the similarity threshold, the response is marked **unaugmented** rather than silently proceeding as if retrieval succeeded — matching the plan doc's R-16/R-17 test rows (zero-chunk query injects nothing; stopping `memory-service` mid-session tells the client the response is unaugmented, not a silent fallback).

4. **Pinned, declared dependencies; telemetry off by default.** `memory-service/requirements.txt` gains exact-pinned `langchain-core`/`langsmith` versions (currently floating via `langgraph`'s transitive resolution). `LANGCHAIN_TRACING_V2` is explicitly set to `false` in the service's own startup, so tracing requires deliberate opt-in even if the env var is set elsewhere on the machine — not just "nobody's turned it on yet."

## Consequences

**Positive**
- Closes the specific "manufactured hallucination" failure mode named in Epic E: stale or irrelevant context can no longer masquerade as authoritative.
- `ai-memory-status` becomes actionable — "the index is 40 commits behind" is a reason to re-index, not a silent unknown.
- Makes the undeclared `langsmith` dependency an explicit, reviewed decision instead of an accidental transitive default.

**Negative**
- Freshness tracking requires `remember()` calls to shell out to `git rev-parse` — adds a small amount of latency and a hard dependency on the caller being inside a git repo (acceptable here; this platform only ever runs against git-tracked projects).
- Attribution metadata increases the size of what's stored per chunk; not expected to matter at this platform's scale (single-project, local-only Chroma collections) but not measured yet.

**Neutral**
- Does not address the plan doc's separate note that three retrieval systems (`memory-service`, `tokensave`, Headroom) coexist on this machine with no defined precedence. That's a real, larger question (which layer is authoritative per harness) explicitly out of scope for this ADR — tracked as a follow-up, not silently folded in here.

## Alternatives considered

- **Rebuild retrieval on a different vector store / framework.** Rejected: the mechanism (Chroma + LangGraph checkpointer) is verified working; the gaps are governance, not the underlying engine. Swapping engines would re-risk what's already proven.
- **Make freshness/attribution advisory (log a warning, keep serving stale context).** Rejected for the zero-chunk case specifically (R-17): a silent fallback to an unaugmented response *looks* identical to a successful augmented one from the client's side, which is the exact ambiguity Epic E flags as the root problem. Fail-closed (mark unaugmented) costs nothing and removes the ambiguity.

## Links
- Source: `docs/bugs/airlock-architectural-implementation-plan (1).md`, Epic E (R-8 through R-20).
- Depends on the existing `memory-service` implementation (commit `8332d85`) and its test suite (`memory-service/tests/`), verified passing this session.
