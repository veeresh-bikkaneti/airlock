"""Airlock memory-service — FastAPI app.

/health — liveness check.
/v1/memory/remember, /v1/memory/recall — long-term memory (Chroma + Ollama embeddings).
/v1/chat/completions — OpenAI-compatible proxy: retrieve -> inject -> forward
to the real backend, checkpointed per session for short-term/working memory.
"""
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel

from .audit import write_audit_log
from .checkpointer import get_checkpointer
from .graph import build_graph
from .memory_store import MemoryStore
from .proxy import DEFAULT_PROJECT_ID, DEFAULT_SESSION_ID, active_provider, call_backend_chat

app = FastAPI(title="Airlock Memory Service")
_store = MemoryStore()
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
def health():
    return {"status": "ok", "service": "airlock-memory-service"}


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


class RecallRequest(BaseModel):
    project_id: str
    query: str
    k: int = 3


class RecallHit(BaseModel):
    text: str
    metadata: dict
    distance: float


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
        return call_backend_chat(messages_in, extra)

    holder: dict = {}

    def forward_fn(messages: list[dict]) -> dict:
        result = call_backend_chat(messages, extra)
        holder["raw"] = result
        choice = result["choices"][0]["message"]
        return {"role": choice.get("role", "assistant"), "content": choice.get("content", "")}

    graph = build_graph(_store, forward_fn).compile(checkpointer=_checkpointer)
    config = {"configurable": {"thread_id": session_id}}
    graph.invoke({"project_id": project_id, "messages": messages_in}, config)

    if "raw" not in holder:
        raise HTTPException(status_code=502, detail="No response from backend")
    return holder["raw"]
