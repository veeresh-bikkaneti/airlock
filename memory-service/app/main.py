"""Airlock memory-service — FastAPI app.

/health — liveness check, plus (ADR-007) index freshness for ai-memory-status.
/v1/memory/remember, /v1/memory/recall — long-term memory (Chroma + Ollama embeddings).
/v1/chat/completions — OpenAI-compatible proxy: retrieve -> inject -> forward
to the real backend, checkpointed per session for short-term/working memory.
"""
import os

# ADR-007 point 4: tracing must require a deliberate opt-in from this
# service's own startup, not just "nobody's set the env var yet" on the
# host machine. Set before any other import so langsmith's cached env-var
# lookup (functools.lru_cache) never observes a stale/host-set value.
# langsmith 0.10+ checks LANGSMITH_TRACING_V2 first, then LANGCHAIN_TRACING_V2
# (see langsmith.utils.get_env_var) — both are pinned off here.
os.environ["LANGCHAIN_TRACING_V2"] = "false"
os.environ["LANGSMITH_TRACING_V2"] = "false"

from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .audit import write_audit_log
from .checkpointer import get_checkpointer
from .config import CHROMA_DIR_CODING
from .embeddings import LlamaCppEmbeddingFunction, embedding_backend_url
from .graph import build_graph
from .memory_store import MemoryStore
from .proxy import (
    DEFAULT_PROJECT_ID,
    DEFAULT_SESSION_ID,
    active_provider,
    call_backend_chat,
    call_coding_backend_chat,
    coding_backend_base_url,
    stream_coding_backend_chat,
)

app = FastAPI(title="Airlock Memory Service")
_store = MemoryStore()
# PENDING item 9: separate store, separate embedding model, separate Chroma
# dir from _store above - see CHROMA_DIR_CODING's docstring (config.py).
_coding_store = MemoryStore(
    embedding_function=LlamaCppEmbeddingFunction(), persist_dir=CHROMA_DIR_CODING
)
_checkpointer = get_checkpointer()
_last_logged_provider: Optional[str] = None


def _check_backend_provider() -> str:
    """Vet the live backend before touching memory. embeddings only work
    against Ollama's /api/embeddings — vLLM's OpenAI server doesn't serve
    that route, so retrieval/persist degrade to a no-op rather than
    crashing or (worse) silently falling back to a cloud embedding API.
    Logs only on transition, not per-request, to avoid spamming the audit log.
    """
    global _last_logged_provider
    provider = active_provider()
    if provider != _last_logged_provider:
        _last_logged_provider = provider
        if provider == "vllm":
            write_audit_log(
                "MemoryDegraded",
                "WARNING",
                message="Backend is vLLM — memory retrieval/persist skipped (embeddings require Ollama)",
            )
        else:
            write_audit_log(
                "MemoryActive", "SUCCESS", message=f"Backend is {provider} — memory retrieval/persist active"
            )
    return provider


@app.get("/health")
def health(project_id: str = DEFAULT_PROJECT_ID):
    # ADR-007 point 2: extended in place rather than adding a new endpoint —
    # ai-memory-status already does a single GET /health round-trip, so
    # freshness rides along in the same response instead of a second call.
    try:
        freshness = _store.freshness(project_id)
    except Exception:
        freshness = None
    return {
        "status": "ok",
        "service": "airlock-memory-service",
        "memoryFreshness": freshness,
    }


class RememberRequest(BaseModel):
    project_id: str
    text: str
    metadata: Optional[dict] = None


class RememberResponse(BaseModel):
    id: str


@app.post("/v1/memory/remember", response_model=RememberResponse)
def remember(req: RememberRequest):
    if _check_backend_provider() == "vllm":
        raise HTTPException(
            status_code=503,
            detail="Memory degraded: backend is vLLM, embeddings require Ollama.",
        )
    doc_id = _store.remember(req.project_id, req.text, req.metadata)
    return RememberResponse(id=doc_id)


@app.post("/coding/v1/memory/remember", response_model=RememberResponse)
def coding_remember(req: RememberRequest):
    """PENDING item 9: same shape as /v1/memory/remember, but persists into
    the coding-path's own store (separate embedding model, separate Chroma
    dir - see _coding_store above). Nothing calls this automatically today
    (same is true of the chat path's /v1/memory/remember - persistence is
    always an explicit call, never silently triggered every turn); this
    exists so a coding session has somewhere real to persist to once
    something (a harness, a hook, a manual call) decides to."""
    if not embedding_backend_url():
        raise HTTPException(
            status_code=503,
            detail="No embedding backend registered - ai-agent-start has not published a llama.cpp embedding endpoint for this session.",
        )
    doc_id = _coding_store.remember(req.project_id, req.text, req.metadata)
    return RememberResponse(id=doc_id)


class RecallRequest(BaseModel):
    project_id: str
    query: str
    # None (not a hardcoded 3) so MemoryStore.recall() falls through to
    # topK from config/memory-service.json (ADR-007 point 1) when the
    # caller doesn't explicitly override it.
    k: Optional[int] = None


class RecallHit(BaseModel):
    text: str
    metadata: dict
    distance: float
    path: Optional[str] = None
    line_range: Optional[str] = None
    indexed_commit_sha: Optional[str] = None
    indexed_at: Optional[str] = None


class RecallResponse(BaseModel):
    hits: list[RecallHit]


@app.post("/v1/memory/recall", response_model=RecallResponse)
def recall(req: RecallRequest):
    if _check_backend_provider() == "vllm":
        raise HTTPException(
            status_code=503,
            detail="Memory degraded: backend is vLLM, embeddings require Ollama.",
        )
    hits = _store.recall(req.project_id, req.query, req.k)
    return RecallResponse(hits=hits)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    session_id = request.headers.get("x-session-id", DEFAULT_SESSION_ID)
    project_id = request.headers.get("x-project-id", DEFAULT_PROJECT_ID)
    messages_in = body.get("messages", [])
    extra = {k: v for k, v in body.items() if k != "messages"}

    if _check_backend_provider() == "vllm":
        # Degraded mode: pure passthrough, no retrieve/persist — chat still
        # works, memory silently no-ops instead of erroring on every turn.
        # ADR-007 R-17: this is the literal "memory-service degraded
        # mid-session" case — mark unaugmented so it's not indistinguishable
        # from a real augmented response on the client side.
        degraded = call_backend_chat(messages_in, extra)
        degraded["airlockMemory"] = {"augmented": False}
        return degraded

    holder: dict = {}

    def forward_fn(messages: list[dict]) -> dict:
        result = call_backend_chat(messages, extra)
        holder["raw"] = result
        choice = result["choices"][0]["message"]
        return {"role": choice.get("role", "assistant"), "content": choice.get("content", "")}

    graph = build_graph(_store, forward_fn).compile(checkpointer=_checkpointer)
    config = {"configurable": {"thread_id": session_id}}
    final_state = graph.invoke({"project_id": project_id, "messages": messages_in}, config)

    if "raw" not in holder:
        raise HTTPException(status_code=502, detail="No response from backend")
    # ADR-007 R-16/R-17: fail-closed — a zero-chunk (or all-below-threshold)
    # retrieval must be visible to the client as unaugmented, not silently
    # indistinguishable from a successful augmented response.
    raw = holder["raw"]
    raw["airlockMemory"] = {"augmented": bool(final_state.get("augmented", False))}
    return raw


def _last_user_content(messages: list[dict]) -> Optional[str]:
    for msg in reversed(messages):
        if msg.get("role") == "user" and msg.get("content"):
            return msg["content"]
    return None


def _recall_and_inject_coding(project_id: str, messages: list[dict]) -> tuple[list[dict], bool]:
    """Real recall for the coding path (PENDING item 9), using the dedicated
    embedding llama-server. Runs BEFORE forwarding - unlike persistence,
    injection doesn't need a complete response, so this works for both the
    streaming path (what Pi actually uses) and the non-streaming one, unlike
    the chat path's LangGraph-based retrieve/inject which assumes a
    buffered response. Degrades to unaugmented (never raises) if no
    embedding backend is registered or recall itself fails - an optional
    enhancement must never block the coding turn from completing."""
    if not embedding_backend_url():
        return messages, False
    last_user = _last_user_content(messages)
    if not last_user:
        return messages, False
    try:
        hits = _coding_store.recall(project_id, last_user)
    except Exception:
        return messages, False
    if not hits:
        return messages, False
    context = "\n".join(f"- {h['text']}" for h in hits)
    injected = [{"role": "system", "content": f"Relevant memory:\n{context}"}] + messages
    return injected, True


@app.post("/coding/v1/chat/completions")
async def coding_chat_completions(request: Request):
    """Separate route (not a shared file/header on /v1/chat/completions) so
    a coding session (ai-agent-start, llama.cpp) can never collide with or
    be confused for a concurrent chat session (ai-start, Ollama/vLLM) - each
    has its own state file and its own endpoint path.

    Real recall/inject (PENDING item 9) via the dedicated embedding
    llama-server, degrading to plain passthrough when that backend isn't
    registered. Persistence is a separate explicit call
    (/coding/v1/memory/remember) - nothing auto-persists every turn here,
    matching the chat path's own always-manual remember() semantics.
    """
    body = await request.json()
    messages = body.get("messages", [])
    extra = {k: v for k, v in body.items() if k != "messages"}
    project_id = request.headers.get("x-project-id", DEFAULT_PROJECT_ID)

    if not coding_backend_base_url():
        raise HTTPException(
            status_code=503,
            detail="No coding backend registered - ai-agent-start has not published a llama.cpp endpoint for this session.",
        )

    messages, augmented = _recall_and_inject_coding(project_id, messages)

    if body.get("stream"):
        # Raw SSE passthrough - no airlockMemory annotation possible
        # mid-stream (would require rewriting the final chunk, not worth it).
        # Recall/injection above already happened before this point though,
        # so Pi's actual (always-streaming) traffic IS augmented when hits
        # exist - only the response-side annotation is streaming-incompatible.
        return StreamingResponse(
            stream_coding_backend_chat(messages, extra), media_type="text/event-stream"
        )

    result = call_coding_backend_chat(messages, extra)
    result["airlockMemory"] = {"augmented": augmented}
    return result
