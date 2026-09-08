"""Embeddings — always local, via Ollama's /api/embeddings.

LangChain's default embedding backends reach for OpenAI, which would leak
conversation content to the cloud and violate provider-policy.json
(allowSensitiveDataToCloud: false). This wrapper only ever talks to the
Ollama instance the platform itself manages, never a cloud provider.
"""
import json

import requests
from chromadb import Documents, EmbeddingFunction, Embeddings

from .config import ACTIVE_PORT_FILE, ACTIVE_PORT_FILE_EMBEDDING, EMBED_MODEL


def active_backend_url() -> str:
    if ACTIVE_PORT_FILE.exists():
        state = json.loads(ACTIVE_PORT_FILE.read_text())
        return f"http://127.0.0.1:{state['port']}"
    return "http://127.0.0.1:12345"


class OllamaEmbeddingFunction(EmbeddingFunction):
    """chromadb-compatible embedding function backed by Ollama."""

    def __init__(self, model: str = EMBED_MODEL, base_url: str | None = None):
        self.model = model
        self.base_url = base_url

    def __call__(self, input: Documents) -> Embeddings:
        base_url = self.base_url or active_backend_url()
        vectors = []
        for text in input:
            resp = requests.post(
                f"{base_url}/api/embeddings",
                json={"model": self.model, "prompt": text},
                timeout=30,
            )
            resp.raise_for_status()
            vectors.append(resp.json()["embedding"])
        return vectors

    @staticmethod
    def name() -> str:
        return "ollama-embeddings"


def embedding_backend_url() -> str | None:
    """The dedicated embedding llama-server's URL, if ai-agent-start has
    registered one for this session. None (not a fallback guess) when
    absent - PENDING item 9's coding-path memory needs its own real
    embedding backend, not a silent default that would point at the wrong
    process."""
    if ACTIVE_PORT_FILE_EMBEDDING.exists():
        state = json.loads(ACTIVE_PORT_FILE_EMBEDDING.read_text())
        return f"http://127.0.0.1:{state['port']}"
    return None


class LlamaCppEmbeddingFunction(EmbeddingFunction):
    """chromadb-compatible embedding function backed by the dedicated
    embedding llama-server (PENDING item 9) - real cross-session memory for
    the coding path. Separate from OllamaEmbeddingFunction: llama.cpp's
    OpenAI-compatible server serves /v1/embeddings, not Ollama's
    /api/embeddings, and the coding path's llama-server (the 27B coding
    model) never runs in --embedding mode itself - this always talks to the
    small, separate embedding-only instance."""

    def __init__(self, base_url: str | None = None):
        self.base_url = base_url

    def __call__(self, input: Documents) -> Embeddings:
        base_url = self.base_url or embedding_backend_url()
        if not base_url:
            raise RuntimeError(
                "No embedding backend registered - ai-agent-start has not "
                "published a llama.cpp embedding endpoint for this session."
            )
        resp = requests.post(
            f"{base_url}/v1/embeddings", json={"input": list(input)}, timeout=30
        )
        resp.raise_for_status()
        data = resp.json()["data"]
        return [item["embedding"] for item in data]

    @staticmethod
    def name() -> str:
        return "llamacpp-embeddings"
