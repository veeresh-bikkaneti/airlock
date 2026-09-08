"""Runnable check: the coding-path embedding function (docs/adr/PENDING.md
item 9) talks to its own dedicated embedding llama-server, never falls back
to a guess, and calls the real OpenAI-compatible /v1/embeddings shape.
"""
import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import embeddings  # noqa: E402


def test_embedding_backend_url_none_when_no_state_file():
    with tempfile.TemporaryDirectory() as tmp:
        fake_path = Path(tmp) / "llamacpp-embedding-instance.json"
        with patch.object(embeddings, "ACTIVE_PORT_FILE_EMBEDDING", fake_path):
            assert embeddings.embedding_backend_url() is None


def test_embedding_backend_url_reads_registered_port():
    with tempfile.TemporaryDirectory() as tmp:
        fake_path = Path(tmp) / "llamacpp-embedding-instance.json"
        fake_path.write_text(json.dumps({"port": 8765}))
        with patch.object(embeddings, "ACTIVE_PORT_FILE_EMBEDDING", fake_path):
            assert embeddings.embedding_backend_url() == "http://127.0.0.1:8765"


def test_llamacpp_embedding_function_raises_when_nothing_registered():
    with tempfile.TemporaryDirectory() as tmp:
        fake_path = Path(tmp) / "llamacpp-embedding-instance.json"
        with patch.object(embeddings, "ACTIVE_PORT_FILE_EMBEDDING", fake_path):
            fn = embeddings.LlamaCppEmbeddingFunction()
            try:
                fn(["hello"])
                assert False, "expected RuntimeError"
            except RuntimeError as exc:
                assert "ai-agent-start" in str(exc)


def test_llamacpp_embedding_function_calls_v1_embeddings():
    fake_response = Mock()
    fake_response.raise_for_status.return_value = None
    fake_response.json.return_value = {
        "data": [{"embedding": [0.1, 0.2]}, {"embedding": [0.3, 0.4]}]
    }
    with patch.object(embeddings.requests, "post", return_value=fake_response) as mock_post:
        fn = embeddings.LlamaCppEmbeddingFunction(base_url="http://127.0.0.1:8765")
        result = fn(["doc one", "doc two"])
        # chromadb's EmbeddingFunction base class wraps __call__ and
        # converts the returned list-of-lists to numpy arrays.
        assert [list(vec) for vec in result] == [[0.1, 0.2], [0.3, 0.4]]
        called_url = mock_post.call_args.args[0]
        called_json = mock_post.call_args.kwargs["json"]
        assert called_url == "http://127.0.0.1:8765/v1/embeddings"
        assert called_json == {"input": ["doc one", "doc two"]}


def test_llamacpp_embedding_function_name():
    assert embeddings.LlamaCppEmbeddingFunction.name() == "llamacpp-embeddings"


if __name__ == "__main__":
    test_embedding_backend_url_none_when_no_state_file()
    test_embedding_backend_url_reads_registered_port()
    test_llamacpp_embedding_function_raises_when_nothing_registered()
    test_llamacpp_embedding_function_calls_v1_embeddings()
    test_llamacpp_embedding_function_name()
    print("All embeddings checks passed")
