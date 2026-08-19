"""Runnable check: proves the routing/translation logic in app/main.py without
a live Ollama - every upstream call is monkeypatched. What this does NOT prove
is model quality (whether qwen2.5-coder:7b actually picks the right tool) -
that's a live/manual check against a running Ollama, not something a unit
test can assert.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.main import app, normalize_messages, ollama_base_url  # noqa: E402


class FakeResponse:
    def __init__(self, status_code=200, json_body=None, text=""):
        self.status_code = status_code
        self.ok = 200 <= status_code < 300
        self._json_body = json_body if json_body is not None else {}
        self.text = text or json.dumps(self._json_body)
        self.headers = {"content-type": "application/json"}

    def json(self):
        return self._json_body


@pytest.fixture
def client():
    return TestClient(app)


TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List files in a directory",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}}},
        },
    }
]


def test_passthrough_when_no_tools_declared(client, monkeypatch):
    captured = {}

    def fake_post(url, json=None, stream=False, timeout=None):
        captured["url"] = url
        captured["json"] = json
        return FakeResponse(json_body={"id": "chatcmpl-x", "choices": []})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "hi"}]},
    )

    assert resp.status_code == 200
    assert captured["url"].endswith("/v1/chat/completions")
    assert resp.json() == {"id": "chatcmpl-x", "choices": []}


def test_tool_call_decision_becomes_openai_tool_calls(client, monkeypatch):
    decision_content = json.dumps({"action": "call_tool", "tool_name": "list_files", "tool_arguments": {"path": "."}})

    def fake_post(url, json=None, timeout=None):
        assert url.endswith("/api/chat")
        assert json["format"]["properties"]["tool_name"]["enum"] == ["list_files"]
        return FakeResponse(
            json_body={
                "message": {"content": decision_content},
                "prompt_eval_count": 10,
                "eval_count": 5,
            }
        )

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "qwen2.5-coder:7b",
            "messages": [{"role": "user", "content": "list files here"}],
            "tools": TOOLS,
        },
    )

    body = resp.json()
    assert resp.status_code == 200
    message = body["choices"][0]["message"]
    assert body["choices"][0]["finish_reason"] == "tool_calls"
    assert message["content"] is None
    call = message["tool_calls"][0]
    assert call["function"]["name"] == "list_files"
    assert json.loads(call["function"]["arguments"]) == {"path": "."}
    assert body["usage"]["total_tokens"] == 15


def test_respond_decision_when_no_tool_needed(client, monkeypatch):
    decision_content = json.dumps({"action": "respond", "response_text": "4"})

    def fake_post(url, json=None, timeout=None):
        return FakeResponse(
            json_body={"message": {"content": decision_content}, "prompt_eval_count": 1, "eval_count": 1}
        )

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "what is 2+2?"}], "tools": TOOLS},
    )

    body = resp.json()
    assert body["choices"][0]["finish_reason"] == "stop"
    assert body["choices"][0]["message"]["content"] == "4"


def test_malformed_json_from_ollama_falls_back_to_raw_text(client, monkeypatch):
    def fake_post(url, json=None, timeout=None):
        return FakeResponse(json_body={"message": {"content": "not json at all"}})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS},
    )

    assert resp.status_code == 200
    assert resp.json()["choices"][0]["message"]["content"] == "not json at all"


def test_upstream_ollama_error_surfaces_as_502(client, monkeypatch):
    def fake_post(url, json=None, timeout=None):
        return FakeResponse(status_code=500, text="model not found")

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "does-not-exist", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS},
    )

    assert resp.status_code == 502
    assert "detail" in resp.json()


def test_normalize_messages_folds_tool_round_trip():
    messages = [
        {"role": "user", "content": "list files"},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {"id": "call_1", "type": "function", "function": {"name": "list_files", "arguments": '{"path": "."}'}}
            ],
        },
        {"role": "tool", "content": "a.txt, b.txt"},
    ]

    normalized = normalize_messages(messages)

    assert normalized[0] == {"role": "user", "content": "list files"}
    assistant_turn = json.loads(normalized[1]["content"])
    assert assistant_turn == {"action": "call_tool", "tool_name": "list_files", "tool_arguments": {"path": "."}}
    assert normalized[2]["role"] == "user"
    assert "a.txt, b.txt" in normalized[2]["content"]


def test_ollama_base_url_env_override(monkeypatch):
    monkeypatch.setenv("OLLAMA_BASE_URL", "http://127.0.0.1:9999/")
    assert ollama_base_url() == "http://127.0.0.1:9999"


def test_ollama_base_url_falls_back_when_no_state_file(monkeypatch):
    monkeypatch.delenv("OLLAMA_BASE_URL", raising=False)
    monkeypatch.setattr("app.main.ACTIVE_PORT_FILE", Path("C:/definitely/does/not/exist.json"))
    assert ollama_base_url() == "http://127.0.0.1:12345"
