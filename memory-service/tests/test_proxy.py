"""Runnable check: the coding-path backend routing (docs/adr/PENDING.md item 9)
never touches the chat path's shared state, and forwards correctly when a
coding backend has actually been registered.
"""
import json
import sys
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import proxy  # noqa: E402


def test_coding_backend_base_url_none_when_no_state_file():
    with tempfile.TemporaryDirectory() as tmp:
        fake_path = Path(tmp) / ".active-port-coding.json"
        with patch.object(proxy, "ACTIVE_PORT_FILE_CODING", fake_path):
            assert proxy.coding_backend_base_url() is None


def test_coding_backend_base_url_reads_registered_port():
    with tempfile.TemporaryDirectory() as tmp:
        fake_path = Path(tmp) / ".active-port-coding.json"
        fake_path.write_text(json.dumps({"port": 63750}))
        with patch.object(proxy, "ACTIVE_PORT_FILE_CODING", fake_path):
            assert proxy.coding_backend_base_url() == "http://127.0.0.1:63750"


def test_coding_backend_base_url_never_reads_the_chat_state_file():
    # The chat path's own file exists and is populated; the coding lookup
    # must not fall back to it - that fallback is exactly the clobbering
    # bug this separate file/route exists to avoid.
    with tempfile.TemporaryDirectory() as tmp:
        chat_path = Path(tmp) / ".active-port.json"
        chat_path.write_text(json.dumps({"port": 12345}))
        coding_path = Path(tmp) / ".active-port-coding.json"
        with patch.object(proxy, "ACTIVE_PORT_FILE", chat_path), \
             patch.object(proxy, "ACTIVE_PORT_FILE_CODING", coding_path):
            assert proxy.coding_backend_base_url() is None


def test_call_coding_backend_chat_raises_when_nothing_registered():
    with tempfile.TemporaryDirectory() as tmp:
        fake_path = Path(tmp) / ".active-port-coding.json"
        with patch.object(proxy, "ACTIVE_PORT_FILE_CODING", fake_path):
            try:
                proxy.call_coding_backend_chat([{"role": "user", "content": "hi"}], {})
                assert False, "expected RuntimeError"
            except RuntimeError as exc:
                assert "ai-agent-start" in str(exc)


def test_call_coding_backend_chat_forwards_to_registered_port():
    with tempfile.TemporaryDirectory() as tmp:
        fake_path = Path(tmp) / ".active-port-coding.json"
        fake_path.write_text(json.dumps({"port": 63750}))
        fake_response = Mock()
        fake_response.json.return_value = {"choices": [{"message": {"content": "ok"}}]}
        fake_response.raise_for_status.return_value = None
        with patch.object(proxy, "ACTIVE_PORT_FILE_CODING", fake_path), \
             patch.object(proxy.requests, "post", return_value=fake_response) as mock_post:
            result = proxy.call_coding_backend_chat([{"role": "user", "content": "hi"}], {"model": "test"})
            assert result == {"choices": [{"message": {"content": "ok"}}]}
            called_url = mock_post.call_args.args[0]
            assert called_url == "http://127.0.0.1:63750/v1/chat/completions"


def test_stream_coding_backend_chat_raises_when_nothing_registered():
    with tempfile.TemporaryDirectory() as tmp:
        fake_path = Path(tmp) / ".active-port-coding.json"
        with patch.object(proxy, "ACTIVE_PORT_FILE_CODING", fake_path):
            try:
                next(proxy.stream_coding_backend_chat([{"role": "user", "content": "hi"}], {}))
                assert False, "expected RuntimeError"
            except RuntimeError as exc:
                assert "ai-agent-start" in str(exc)


def test_stream_coding_backend_chat_forwards_chunks_and_forces_stream_true():
    # PENDING.md item 9 regression: the non-streaming path forces
    # stream=False; the streaming path must do the opposite - Pi requests
    # stream=True and forcing it off broke tool-call parsing client-side
    # even though the underlying HTTP call succeeded (found live).
    with tempfile.TemporaryDirectory() as tmp:
        fake_path = Path(tmp) / ".active-port-coding.json"
        fake_path.write_text(json.dumps({"port": 63750}))
        fake_response = Mock()
        fake_response.raise_for_status.return_value = None
        fake_response.iter_content.return_value = iter([b"data: chunk1\n\n", b"data: chunk2\n\n"])
        fake_response.__enter__ = Mock(return_value=fake_response)
        fake_response.__exit__ = Mock(return_value=False)
        with patch.object(proxy, "ACTIVE_PORT_FILE_CODING", fake_path), \
             patch.object(proxy.requests, "post", return_value=fake_response) as mock_post:
            chunks = list(proxy.stream_coding_backend_chat([{"role": "user", "content": "hi"}], {"stream": False}))
            assert chunks == [b"data: chunk1\n\n", b"data: chunk2\n\n"]
            assert mock_post.call_args.kwargs["json"]["stream"] is True
            assert mock_post.call_args.kwargs["stream"] is True


if __name__ == "__main__":
    test_coding_backend_base_url_none_when_no_state_file()
    test_coding_backend_base_url_reads_registered_port()
    test_coding_backend_base_url_never_reads_the_chat_state_file()
    test_call_coding_backend_chat_raises_when_nothing_registered()
    test_call_coding_backend_chat_forwards_to_registered_port()
    test_stream_coding_backend_chat_raises_when_nothing_registered()
    test_stream_coding_backend_chat_forwards_chunks_and_forces_stream_true()
    print("All proxy checks passed")
