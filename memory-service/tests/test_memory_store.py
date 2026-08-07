"""Runnable check: store 3 docs, query, assert the right one is top-1.

Uses a deterministic bag-of-words embedding instead of live Ollama so this
runs offline — it proves the Chroma store/query mechanics are wired
correctly, not embedding quality (that's Ollama's job, exercised manually
via /v1/memory/remember + /v1/memory/recall against a running backend).
"""
import shutil
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from chromadb import EmbeddingFunction  # noqa: E402

from app.memory_store import MemoryStore  # noqa: E402


class FakeBagOfWordsEmbedding(EmbeddingFunction):
    DIM = 256

    def __init__(self):
        pass

    def __call__(self, input):
        vectors = []
        for text in input:
            vec = [0.0] * self.DIM
            for word in text.lower().split():
                vec[hash(word) % self.DIM] += 1.0
            norm = sum(v * v for v in vec) ** 0.5 or 1.0
            vectors.append([v / norm for v in vec])
        return vectors

    @staticmethod
    def name() -> str:
        return "fake-bow"


@contextmanager
def _tmp_chroma_dir():
    # chromadb's sqlite/hnsw file handles aren't released deterministically on
    # Windows, so TemporaryDirectory's strict cleanup can raise PermissionError
    # even though the test itself passed. Best-effort cleanup instead.
    path = tempfile.mkdtemp(prefix="memory-store-test-")
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def test_remember_and_recall_top1():
    with _tmp_chroma_dir() as tmp:
        store = MemoryStore(embedding_function=FakeBagOfWordsEmbedding(), persist_dir=tmp)

        store.remember("proj-a", "the user's cat is named whiskers and loves tuna")
        store.remember("proj-a", "deploy pipeline uses github actions and runs on port 12345")
        store.remember("proj-a", "favorite pizza topping is pepperoni with extra cheese")

        hits = store.recall("proj-a", "whiskers the cat", k=1)

        assert len(hits) == 1
        assert "whiskers" in hits[0]["text"]


def test_recall_is_scoped_per_project():
    with _tmp_chroma_dir() as tmp:
        store = MemoryStore(embedding_function=FakeBagOfWordsEmbedding(), persist_dir=tmp)

        store.remember("proj-a", "whiskers the cat loves tuna")

        hits = store.recall("proj-b", "whiskers the cat", k=1)

        assert hits == []


if __name__ == "__main__":
    test_remember_and_recall_top1()
    test_recall_is_scoped_per_project()
    print("OK: memory_store store/query/top-1 + project-scoping checks passed")
