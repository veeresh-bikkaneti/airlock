"""Runnable check: short-term/working memory survives across two separate
graph invocations with the same thread_id, without the client resending
history — that's the whole point of the SqliteSaver checkpointer.

Uses a fake forward_fn (stands in for the real backend call, wired up in
Phase 4) so this runs offline.
"""
import shutil
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from chromadb import EmbeddingFunction  # noqa: E402

from app.checkpointer import get_checkpointer  # noqa: E402
from app.graph import build_graph  # noqa: E402
from app.memory_store import MemoryStore  # noqa: E402


class FakeEmbedding(EmbeddingFunction):
    def __init__(self):
        pass

    def __call__(self, input):
        return [[0.0] for _ in input]

    @staticmethod
    def name() -> str:
        return "fake-noop"


@contextmanager
def _tmp_dir():
    path = tempfile.mkdtemp(prefix="graph-test-")
    try:
        yield Path(path)
    finally:
        shutil.rmtree(path, ignore_errors=True)


def test_second_call_sees_first_calls_context_without_resend():
    with _tmp_dir() as tmp:
        store = MemoryStore(embedding_function=FakeEmbedding(), persist_dir=tmp / "chroma")
        checkpointer = get_checkpointer(tmp / "checkpoints.sqlite")

        seen_on_each_call = []

        def fake_forward(messages: list[dict]) -> dict:
            seen_on_each_call.append([m["content"] for m in messages])
            return {"role": "assistant", "content": f"echo: {messages[-1]['content']}"}

        compiled = build_graph(store, fake_forward).compile(checkpointer=checkpointer)
        config = {"configurable": {"thread_id": "session-1"}}

        compiled.invoke(
            {"project_id": "proj-a", "messages": [{"role": "user", "content": "my favorite color is blue"}]},
            config,
        )
        compiled.invoke(
            {"project_id": "proj-a", "messages": [{"role": "user", "content": "what did I just say?"}]},
            config,
        )

        # Second call was given ONLY the new user turn (no resent history) —
        # if the checkpointer works, forward_fn still saw the first turn.
        second_call_context = seen_on_each_call[-1]
        assert any("blue" in c for c in second_call_context)


def test_different_thread_id_has_no_shared_context():
    with _tmp_dir() as tmp:
        store = MemoryStore(embedding_function=FakeEmbedding(), persist_dir=tmp / "chroma")
        checkpointer = get_checkpointer(tmp / "checkpoints.sqlite")

        seen_on_each_call = []

        def fake_forward(messages: list[dict]) -> dict:
            seen_on_each_call.append([m["content"] for m in messages])
            return {"role": "assistant", "content": "ack"}

        compiled = build_graph(store, fake_forward).compile(checkpointer=checkpointer)

        compiled.invoke(
            {"project_id": "proj-a", "messages": [{"role": "user", "content": "my favorite color is blue"}]},
            {"configurable": {"thread_id": "session-1"}},
        )
        compiled.invoke(
            {"project_id": "proj-a", "messages": [{"role": "user", "content": "what did I just say?"}]},
            {"configurable": {"thread_id": "session-2"}},
        )

        second_call_context = seen_on_each_call[-1]
        assert not any("blue" in c for c in second_call_context)


if __name__ == "__main__":
    test_second_call_sees_first_calls_context_without_resend()
    test_different_thread_id_has_no_shared_context()
    print("OK: checkpointer continuity + thread isolation checks passed")
