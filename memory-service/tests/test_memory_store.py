"""Runnable check: store 3 docs, query, assert the right one is top-1.

Uses a deterministic bag-of-words embedding instead of live Ollama so this
runs offline — it proves the Chroma store/query mechanics are wired
correctly, not embedding quality (that's Ollama's job, exercised manually
via /v1/memory/remember + /v1/memory/recall against a running backend).
"""
import json
import shutil
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
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


def _write_config(tmp_dir: str, **overrides) -> Path:
    cfg = {
        "embeddingModel": "nomic-embed-text",
        "vectorStore": "chroma",
        "indexPath": None,
        "chunkingStrategy": "none",
        "topK": 3,
        "similarityThreshold": 1.2,
    }
    cfg.update(overrides)
    path = Path(tmp_dir) / "custom-memory-service.json"
    path.write_text(json.dumps(cfg), encoding="utf-8")
    return path


def test_remember_records_freshness_metadata():
    """ADR-007 point 2: every remember() call stamps commit SHA + UTC
    timestamp into the chunk's metadata, and recall() surfaces both."""
    with _tmp_chroma_dir() as tmp:
        store = MemoryStore(embedding_function=FakeBagOfWordsEmbedding(), persist_dir=tmp)

        text = "a document to check freshness metadata"
        store.remember("proj-a", text)
        hits = store.recall("proj-a", text, k=1)

        assert len(hits) == 1
        assert hits[0]["indexed_at"] is not None
        indexed_dt = datetime.fromisoformat(hits[0]["indexed_at"])
        assert (datetime.now(timezone.utc) - indexed_dt).total_seconds() < 60
        # This repo is git-tracked, so a real SHA should be captured — not
        # asserting the literal value (it changes), just that it's present.
        assert hits[0]["indexed_commit_sha"] is not None


def test_zero_chunk_query_returns_no_hits():
    """ADR-007 R-17: an empty index yields zero chunks, not a crash or a
    fabricated match — the caller (graph.py) uses this to mark the response
    unaugmented rather than silently proceeding."""
    with _tmp_chroma_dir() as tmp:
        store = MemoryStore(embedding_function=FakeBagOfWordsEmbedding(), persist_dir=tmp)
        assert store.recall("proj-empty", "anything at all") == []


def test_recall_returns_attribution_fields_when_present():
    with _tmp_chroma_dir() as tmp:
        store = MemoryStore(embedding_function=FakeBagOfWordsEmbedding(), persist_dir=tmp)
        text = "function definition for parse_config"
        store.remember("proj-a", text, {"path": "app/config.py", "start_line": 10, "end_line": 20})

        hits = store.recall("proj-a", text, k=1)

        assert hits[0]["path"] == "app/config.py"
        assert hits[0]["line_range"] == "10-20"


def test_topk_is_read_from_config_file_not_hardcoded():
    """ADR-007 point 1: MemoryStore.__init__ reads topK from
    config/memory-service.json (or the config_path override, here), not a
    hardcoded constructor default."""
    with _tmp_chroma_dir() as tmp:
        cfg_path = _write_config(tmp, topK=1)
        store = MemoryStore(
            embedding_function=FakeBagOfWordsEmbedding(), persist_dir=tmp, config_path=cfg_path
        )
        store.remember("proj-a", "cat cat cat whiskers tuna snack")
        store.remember("proj-a", "cat lounges tuna whiskers snack bowl")
        store.remember("proj-a", "cat purrs whiskers tuna bowl treat")

        hits = store.recall("proj-a", "whiskers tuna cat")  # no k= override
        assert len(hits) == 1


def test_similarity_threshold_is_read_from_config_file_not_hardcoded():
    with _tmp_chroma_dir() as tmp:
        cfg_path = _write_config(tmp, similarityThreshold=0.001)
        store = MemoryStore(
            embedding_function=FakeBagOfWordsEmbedding(), persist_dir=tmp, config_path=cfg_path
        )
        store.remember("proj-a", "deploy pipeline uses github actions")

        # Distinct wording from the stored doc -> distance > 0.001, filtered out.
        hits = store.recall("proj-a", "totally unrelated pizza topping")
        assert hits == []


if __name__ == "__main__":
    test_remember_and_recall_top1()
    test_recall_is_scoped_per_project()
    test_remember_records_freshness_metadata()
    test_zero_chunk_query_returns_no_hits()
    test_recall_returns_attribution_fields_when_present()
    test_topk_is_read_from_config_file_not_hardcoded()
    test_similarity_threshold_is_read_from_config_file_not_hardcoded()
    print("OK: memory_store store/query/top-1 + project-scoping checks passed")
