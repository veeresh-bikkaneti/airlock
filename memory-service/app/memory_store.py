"""Long-term memory: a Chroma collection per project.

One collection per project (keyed by a hash of the project path) rather
than one global collection, so recall for project A never surfaces
memories written while working in project B.
"""
import hashlib
from typing import Optional

import chromadb
from chromadb import EmbeddingFunction

from .config import CHROMA_DIR
from .embeddings import OllamaEmbeddingFunction


def _collection_name(project_id: str) -> str:
    digest = hashlib.sha256(project_id.encode()).hexdigest()[:16]
    return f"project-{digest}"


class MemoryStore:
    def __init__(
        self,
        embedding_function: Optional[EmbeddingFunction] = None,
        persist_dir=None,
    ):
        self._client = chromadb.PersistentClient(path=str(persist_dir or CHROMA_DIR))
        self._embedding_function = embedding_function or OllamaEmbeddingFunction()

    def _collection(self, project_id: str):
        return self._client.get_or_create_collection(
            name=_collection_name(project_id),
            embedding_function=self._embedding_function,
        )

    def remember(self, project_id: str, text: str, metadata: Optional[dict] = None) -> str:
        collection = self._collection(project_id)
        doc_id = hashlib.sha256(f"{project_id}:{text}".encode()).hexdigest()
        collection.upsert(
            ids=[doc_id],
            documents=[text],
            metadatas=[metadata or {"source": "memory-service"}],
        )
        return doc_id

    def recall(self, project_id: str, query: str, k: int = 3) -> list[dict]:
        collection = self._collection(project_id)
        count = collection.count()
        if count == 0:
            return []
        result = collection.query(query_texts=[query], n_results=min(k, count))
        hits = []
        for doc, meta, dist in zip(
            result["documents"][0], result["metadatas"][0], result["distances"][0]
        ):
            hits.append({"text": doc, "metadata": meta, "distance": dist})
        return hits
