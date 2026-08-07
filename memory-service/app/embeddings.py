"""Embeddings — always local, via Ollama's /api/embeddings.

LangChain's default embedding backends reach for OpenAI, which would leak
conversation content to the cloud and violate provider-policy.json
(allowSensitiveDataToCloud: false). This wrapper only ever talks to the
Ollama instance the platform itself manages, never a cloud provider.
"""
import json

import requests
from chromadb import Documents, EmbeddingFunction, Embeddings

from .config import ACTIVE_PORT_FILE, EMBED_MODEL


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
