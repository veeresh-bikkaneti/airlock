"""Runnable check: the coding-path recall/inject wiring (docs/adr/PENDING.md
item 9) degrades cleanly when no embedding backend is registered, and
actually injects retrieved memories into the message list before forwarding
when hits exist.
"""
import sys
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import main  # noqa: E402


def test_last_user_content_finds_the_most_recent_user_message():
    messages = [
        {"role": "system", "content": "you are helpful"},
        {"role": "user", "content": "first question"},
        {"role": "assistant", "content": "first answer"},
        {"role": "user", "content": "second question"},
    ]
    assert main._last_user_content(messages) == "second question"


def test_last_user_content_none_when_no_user_message():
    messages = [{"role": "system", "content": "you are helpful"}]
    assert main._last_user_content(messages) is None


def test_recall_and_inject_degrades_when_no_embedding_backend():
    messages = [{"role": "user", "content": "what did we decide about the VRAM gate"}]
    with patch.object(main, "embedding_backend_url", return_value=None):
        result_messages, augmented = main._recall_and_inject_coding("proj", messages)
        assert result_messages == messages
        assert augmented is False


def test_recall_and_inject_degrades_when_no_user_message():
    messages = [{"role": "system", "content": "you are helpful"}]
    with patch.object(main, "embedding_backend_url", return_value="http://127.0.0.1:8765"):
        result_messages, augmented = main._recall_and_inject_coding("proj", messages)
        assert result_messages == messages
        assert augmented is False


def test_recall_and_inject_degrades_when_recall_raises():
    messages = [{"role": "user", "content": "what did we decide about the VRAM gate"}]
    with patch.object(main, "embedding_backend_url", return_value="http://127.0.0.1:8765"), \
         patch.object(main._coding_store, "recall", side_effect=RuntimeError("embedding backend down")):
        result_messages, augmented = main._recall_and_inject_coding("proj", messages)
        assert result_messages == messages
        assert augmented is False


def test_recall_and_inject_degrades_when_no_hits():
    messages = [{"role": "user", "content": "what did we decide about the VRAM gate"}]
    with patch.object(main, "embedding_backend_url", return_value="http://127.0.0.1:8765"), \
         patch.object(main._coding_store, "recall", return_value=[]):
        result_messages, augmented = main._recall_and_inject_coding("proj", messages)
        assert result_messages == messages
        assert augmented is False


def test_recall_and_inject_prepends_a_system_message_when_hits_exist():
    messages = [{"role": "user", "content": "what did we decide about the VRAM gate"}]
    fake_hits = [{"text": "VRAM gate only runs when needStart is true"}]
    with patch.object(main, "embedding_backend_url", return_value="http://127.0.0.1:8765"), \
         patch.object(main._coding_store, "recall", return_value=fake_hits):
        result_messages, augmented = main._recall_and_inject_coding("proj", messages)
        assert augmented is True
        assert len(result_messages) == 2
        assert result_messages[0]["role"] == "system"
        assert "VRAM gate only runs when needStart is true" in result_messages[0]["content"]
        assert result_messages[1] == messages[0]


if __name__ == "__main__":
    test_last_user_content_finds_the_most_recent_user_message()
    test_last_user_content_none_when_no_user_message()
    test_recall_and_inject_degrades_when_no_embedding_backend()
    test_recall_and_inject_degrades_when_no_user_message()
    test_recall_and_inject_degrades_when_recall_raises()
    test_recall_and_inject_degrades_when_no_hits()
    test_recall_and_inject_prepends_a_system_message_when_hits_exist()
    print("All main coding-route checks passed")
