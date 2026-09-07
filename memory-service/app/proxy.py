"""Forwarding to the real backend (Ollama/vLLM) on its own port.

Non-streaming for v1: the memory graph needs a complete reply to persist
into the checkpointer/long-term store, so streaming straight through to the
client is a follow-up, not a blocker for memory working at all.
"""
import json
from typing import Optional

import requests

from .config import ACTIVE_PORT_FILE, ACTIVE_PORT_FILE_CODING, PLATFORM_DIR

PROVIDER_STATE_FILE = PLATFORM_DIR / "state" / "active-provider.json"

DEFAULT_SESSION_ID = "default-session"
DEFAULT_PROJECT_ID = "default-project"


def active_backend_base_url() -> str:
    if ACTIVE_PORT_FILE.exists():
        state = json.loads(ACTIVE_PORT_FILE.read_text())
        return f"http://127.0.0.1:{state['port']}"
    return "http://127.0.0.1:12345"


def active_model(fallback: Optional[str] = None) -> str:
    if PROVIDER_STATE_FILE.exists():
        state = json.loads(PROVIDER_STATE_FILE.read_text())
        return state.get("model", fallback or "")
    return fallback or ""


def active_provider(fallback: str = "ollama") -> str:
    if PROVIDER_STATE_FILE.exists():
        state = json.loads(PROVIDER_STATE_FILE.read_text())
        return state.get("provider", fallback)
    return fallback


def call_backend_chat(messages: list[dict], extra: dict) -> dict:
    payload = dict(extra)
    payload["messages"] = messages
    payload.setdefault("model", active_model())
    payload["stream"] = False
    resp = requests.post(
        f"{active_backend_base_url()}/v1/chat/completions", json=payload, timeout=120
    )
    resp.raise_for_status()
    return resp.json()


def coding_backend_base_url() -> Optional[str]:
    """The llama.cpp backend ai-agent-start registered for THIS coding
    session, if any. Separate file from active_backend_base_url() on
    purpose - see ACTIVE_PORT_FILE_CODING's docstring in config.py."""
    if ACTIVE_PORT_FILE_CODING.exists():
        state = json.loads(ACTIVE_PORT_FILE_CODING.read_text())
        return f"http://127.0.0.1:{state['port']}"
    return None


def call_coding_backend_chat(messages: list[dict], extra: dict) -> dict:
    base_url = coding_backend_base_url()
    if not base_url:
        raise RuntimeError(
            "No coding backend registered - ai-agent-start has not published "
            "a llama.cpp endpoint for this session."
        )
    payload = dict(extra)
    payload["messages"] = messages
    payload["stream"] = False
    resp = requests.post(f"{base_url}/v1/chat/completions", json=payload, timeout=120)
    resp.raise_for_status()
    return resp.json()


def stream_coding_backend_chat(messages: list[dict], extra: dict):
    """Streaming counterpart to call_coding_backend_chat. Pi (and most
    OpenAI-compatible clients) request stream=True by default and parse
    tool-call events incrementally out of the SSE chunks - collapsing to a
    single buffered JSON response (as call_coding_backend_chat does) breaks
    that parsing even though the underlying HTTP call succeeds (found live:
    200 OK on every request, but the client-side tool-call observation still
    failed). No RAG injection happens on this passthrough route regardless
    of streaming, so there is nothing to buffer for - forward llama.cpp's
    raw SSE bytes straight through.
    """
    base_url = coding_backend_base_url()
    if not base_url:
        raise RuntimeError(
            "No coding backend registered - ai-agent-start has not published "
            "a llama.cpp endpoint for this session."
        )
    payload = dict(extra)
    payload["messages"] = messages
    payload["stream"] = True
    with requests.post(
        f"{base_url}/v1/chat/completions", json=payload, timeout=120, stream=True
    ) as resp:
        resp.raise_for_status()
        for chunk in resp.iter_content(chunk_size=None):
            if chunk:
                yield chunk
