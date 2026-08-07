"""Forwarding to the real backend (Ollama/vLLM) on its own port.

Non-streaming for v1: the memory graph needs a complete reply to persist
into the checkpointer/long-term store, so streaming straight through to the
client is a follow-up, not a blocker for memory working at all.
"""
import json
from typing import Optional

import requests

from .config import ACTIVE_PORT_FILE, PLATFORM_DIR

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
