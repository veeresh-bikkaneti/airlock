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
import requests  # noqa: E402
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


# --- BUG-1: streaming ignored on tool-call requests ---


def test_tool_call_response_streamed_as_sse_when_client_requests_it(client, monkeypatch):
    decision_content = json.dumps({"action": "call_tool", "tool_name": "list_files", "tool_arguments": {"path": "."}})

    def fake_post(url, json=None, timeout=None):
        assert json["stream"] is False, "Ollama call itself stays non-streaming - only the client-facing shape changes"
        return FakeResponse(json_body={"message": {"content": decision_content}, "prompt_eval_count": 1, "eval_count": 1})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "qwen2.5-coder:7b",
            "messages": [{"role": "user", "content": "list files"}],
            "tools": TOOLS,
            "stream": True,
        },
    )

    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/event-stream")
    body = resp.text
    assert body.startswith("data: ")
    assert body.rstrip().endswith("data: [DONE]")
    first_line = body.splitlines()[0][len("data: "):]
    chunk = json.loads(first_line)
    assert chunk["object"] == "chat.completion.chunk"
    assert chunk["choices"][0]["delta"]["tool_calls"][0]["function"]["name"] == "list_files"
    assert chunk["choices"][0]["finish_reason"] == "tool_calls"


def test_tool_call_response_stays_json_when_client_does_not_stream(client, monkeypatch):
    decision_content = json.dumps({"action": "respond", "response_text": "4"})

    def fake_post(url, json=None, timeout=None):
        return FakeResponse(json_body={"message": {"content": decision_content}, "prompt_eval_count": 1, "eval_count": 1})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS, "stream": False},
    )

    assert resp.headers["content-type"].startswith("application/json")


# --- BUG-2: tool briefing should merge into an existing system message ---


def test_briefing_merges_into_existing_system_message(client, monkeypatch):
    captured = {}

    def fake_post(url, json=None, timeout=None):
        captured["messages"] = json["messages"]
        return FakeResponse(json_body={"message": {"content": '{"action": "respond", "response_text": "ok"}'}})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    client.post(
        "/v1/chat/completions",
        json={
            "model": "qwen2.5-coder:7b",
            "messages": [
                {"role": "system", "content": "You are a helpful coding assistant."},
                {"role": "user", "content": "hi"},
            ],
            "tools": TOOLS,
        },
    )

    system_messages = [m for m in captured["messages"] if m["role"] == "system"]
    assert len(system_messages) == 1
    assert "You are a helpful coding assistant." in system_messages[0]["content"]
    assert "list_files" in system_messages[0]["content"]


def test_briefing_prepended_when_no_existing_system_message(client, monkeypatch):
    captured = {}

    def fake_post(url, json=None, timeout=None):
        captured["messages"] = json["messages"]
        return FakeResponse(json_body={"message": {"content": '{"action": "respond", "response_text": "ok"}'}})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS},
    )

    system_messages = [m for m in captured["messages"] if m["role"] == "system"]
    assert len(system_messages) == 1


# --- BUG-3: malformed tool defs shouldn't populate the router enum ---


def test_malformed_tool_def_excluded_from_router_enum(client, monkeypatch):
    captured = {}

    def fake_post(url, json=None, timeout=None):
        captured["format"] = json["format"]
        return FakeResponse(json_body={"message": {"content": '{"action": "respond", "response_text": "ok"}'}})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    broken_and_good_tools = [
        {"type": "function", "function": {"description": "Broken tool - no name", "parameters": {}}},
        {"type": "function", "function": {"name": "good_tool", "description": "Works", "parameters": {}}},
    ]

    client.post(
        "/v1/chat/completions",
        json={"model": "test", "messages": [{"role": "user", "content": "hi"}], "tools": broken_and_good_tools},
    )

    assert captured["format"]["properties"]["tool_name"]["enum"] == ["good_tool"]


# --- BUG-6: vLLM backend should bypass the Ollama-only grammar path ---


def test_vllm_backend_passes_tool_requests_through_openai_endpoint(client, monkeypatch, tmp_path):
    provider_file = tmp_path / "active-provider.json"
    provider_file.write_text(json.dumps({"provider": "vllm"}))
    monkeypatch.setattr("app.main.ACTIVE_PROVIDER_FILE", provider_file)

    captured = {}

    def fake_post(url, json=None, stream=False, timeout=None):
        captured["url"] = url
        captured["json"] = json
        return FakeResponse(json_body={"id": "chatcmpl-vllm", "choices": [{"message": {"content": "vllm handled it"}}]})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "some-vllm-model", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS},
    )

    assert resp.status_code == 200
    assert captured["url"].endswith("/v1/chat/completions")
    assert captured["json"]["tools"] == TOOLS
    assert resp.json()["choices"][0]["message"]["content"] == "vllm handled it"


def test_ollama_backend_still_uses_grammar_path_when_no_provider_file(client, monkeypatch, tmp_path):
    monkeypatch.setattr("app.main.ACTIVE_PROVIDER_FILE", tmp_path / "does-not-exist.json")

    captured = {}

    def fake_post(url, json=None, timeout=None):
        captured["url"] = url
        return FakeResponse(json_body={"message": {"content": '{"action": "respond", "response_text": "ok"}'}})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS},
    )

    assert captured["url"].endswith("/api/chat")


# --- wire-level failure modes: none of the three requests.post call sites had
# exception handling before this - a dead/slow Ollama crashed the proxy with
# an unhandled exception (FastAPI 500) instead of a client-facing 502 ---


def test_ollama_connection_refused_surfaces_as_502_not_crash(client, monkeypatch):
    def fake_post(url, json=None, timeout=None):
        raise requests.exceptions.ConnectionError("Connection refused")

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS},
    )

    assert resp.status_code == 502


def test_ollama_timeout_surfaces_as_502_not_crash(client, monkeypatch):
    def fake_post(url, json=None, timeout=None):
        raise requests.exceptions.Timeout("timed out")

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS},
    )

    assert resp.status_code == 502


def test_no_tools_passthrough_connection_error_surfaces_as_502_not_crash(client, monkeypatch):
    def fake_post(url, json=None, stream=False, timeout=None):
        raise requests.exceptions.ConnectionError("Connection refused")

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "hi"}]},
    )

    assert resp.status_code == 502


def test_vllm_backend_connection_error_surfaces_as_502_not_crash(client, monkeypatch, tmp_path):
    provider_file = tmp_path / "active-provider.json"
    provider_file.write_text(json.dumps({"provider": "vllm"}))
    monkeypatch.setattr("app.main.ACTIVE_PROVIDER_FILE", provider_file)

    def fake_post(url, json=None, stream=False, timeout=None):
        raise requests.exceptions.ConnectionError("Connection refused")

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "some-vllm-model", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS},
    )

    assert resp.status_code == 502


def test_ollama_200_with_unparseable_body_surfaces_as_502_not_crash(client, monkeypatch):
    class BadJsonResponse:
        status_code = 200
        ok = True
        text = "not actually json"

        def json(self):
            raise json.JSONDecodeError("Expecting value", "not actually json", 0)

    def fake_post(url, json=None, timeout=None):
        return BadJsonResponse()

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [{"role": "user", "content": "hi"}], "tools": TOOLS},
    )

    assert resp.status_code == 502


# --- messages edge cases the proxy hadn't been fed before ---


def test_empty_messages_array_with_tools_does_not_crash(client, monkeypatch):
    def fake_post(url, json=None, timeout=None):
        return FakeResponse(json_body={"message": {"content": '{"action": "respond", "response_text": "ok"}'}})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "qwen2.5-coder:7b", "messages": [], "tools": TOOLS},
    )

    assert resp.status_code == 200


def test_second_turn_echoes_prior_router_json_without_double_encoding(client, monkeypatch):
    """A second-turn request replays the assistant's own prior router-shaped
    content verbatim (normalize_messages only special-cases messages carrying
    OpenAI's `tool_calls` field, not plain assistant content that happens to
    look like the router JSON) - confirm it passes through untouched rather
    than being re-wrapped or mangled.
    """
    captured = {}
    prior_router_json = json.dumps({"action": "call_tool", "tool_name": "list_files", "tool_arguments": {"path": "."}})

    def fake_post(url, json=None, timeout=None):
        captured["messages"] = json["messages"]
        return FakeResponse(json_body={"message": {"content": '{"action": "respond", "response_text": "done"}'}})

    monkeypatch.setattr("app.main.requests.post", fake_post)

    client.post(
        "/v1/chat/completions",
        json={
            "model": "qwen2.5-coder:7b",
            "messages": [
                {"role": "user", "content": "list files"},
                {"role": "assistant", "content": prior_router_json},
                {"role": "user", "content": "Tool result: a.txt, b.txt"},
                {"role": "user", "content": "now delete a.txt"},
            ],
            "tools": TOOLS,
        },
    )

    assistant_turns = [m for m in captured["messages"] if m["role"] == "assistant"]
    assert assistant_turns[0]["content"] == prior_router_json


def test_multiple_tool_calls_in_one_assistant_turn_only_first_is_kept(client, monkeypatch):
    """Documents a real limitation: normalize_messages only folds
    tool_calls[0] into history. If a harness ever sends multiple tool calls
    in one assistant turn, every call after the first is silently dropped
    from what the model sees on the next turn.
    """
    messages = [
        {"role": "user", "content": "list files then check disk space"},
        {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {"id": "call_1", "type": "function", "function": {"name": "list_files", "arguments": "{}"}},
                {"id": "call_2", "type": "function", "function": {"name": "disk_space", "arguments": "{}"}},
            ],
        },
    ]

    normalized = normalize_messages(messages)

    assistant_turn = json.loads(normalized[1]["content"])
    assert assistant_turn["tool_name"] == "list_files"


# --- adversarial review findings: malformed client input crashed the proxy
# with an unhandled 500 instead of the "surface raw text, don't crash the
# caller" behavior the file's own docstrings promise ---


def test_non_dict_function_in_tool_def_does_not_crash(client, monkeypatch):
    monkeypatch.setattr("app.main.requests.post", lambda *a, **k: FakeResponse(
        json_body={"message": {"content": '{"action": "respond", "response_text": "ok"}'}}
    ))

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "m",
            "tools": [{"type": "function", "function": "not-a-dict"}],
            "messages": [{"role": "user", "content": "hi"}],
        },
    )

    assert resp.status_code != 500


def test_null_messages_does_not_crash(client):
    resp = client.post("/v1/chat/completions", json={"model": "m", "messages": None})
    assert resp.status_code != 500


def test_non_dict_body_does_not_crash(client):
    resp = client.post("/v1/chat/completions", content=b"42", headers={"content-type": "application/json"})
    assert resp.status_code != 500


def test_tool_call_missing_function_key_does_not_crash(client, monkeypatch):
    monkeypatch.setattr("app.main.requests.post", lambda *a, **k: FakeResponse(
        json_body={"message": {"content": '{"action": "respond", "response_text": "ok"}'}}
    ))

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "m",
            "tools": TOOLS,
            "messages": [{"role": "assistant", "tool_calls": [{"id": "x", "type": "function"}]}],
        },
    )

    assert resp.status_code != 500


def test_tool_call_arguments_as_object_not_string_does_not_crash(client, monkeypatch):
    monkeypatch.setattr("app.main.requests.post", lambda *a, **k: FakeResponse(
        json_body={"message": {"content": '{"action": "respond", "response_text": "ok"}'}}
    ))

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "m",
            "tools": TOOLS,
            "messages": [
                {
                    "role": "assistant",
                    "tool_calls": [{"function": {"name": "list_files", "arguments": {"path": "."}}}],
                }
            ],
        },
    )

    assert resp.status_code != 500


def test_vllm_backend_honors_client_stream_flag(client, monkeypatch, tmp_path):
    provider_file = tmp_path / "active-provider.json"
    provider_file.write_text(json.dumps({"provider": "vllm"}))
    monkeypatch.setattr("app.main.ACTIVE_PROVIDER_FILE", provider_file)

    def fake_post(url, json=None, stream=False, timeout=None):
        sse_body = b'data: {"id":"x","choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n'

        class SSEResponse:
            status_code = 200
            headers = {"content-type": "text/event-stream"}

            def iter_content(self, chunk_size=None):
                yield sse_body

        return SSEResponse()

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "m", "stream": True, "tools": TOOLS, "messages": [{"role": "user", "content": "hi"}]},
    )

    assert resp.status_code != 500
    assert resp.headers["content-type"].startswith("text/event-stream")


def test_models_endpoint_upstream_connection_error_surfaces_as_502_not_crash(client, monkeypatch):
    def fake_get(url, timeout=None):
        raise requests.exceptions.ConnectionError("refused")

    monkeypatch.setattr("app.main.requests.get", fake_get)

    resp = client.get("/v1/models")

    assert resp.status_code == 502


def test_active_port_file_with_null_port_falls_back_instead_of_crashing(monkeypatch, tmp_path):
    from app.main import ollama_base_url

    port_file = tmp_path / ".active-port.json"
    port_file.write_text(json.dumps({"port": None}))
    monkeypatch.delenv("OLLAMA_BASE_URL", raising=False)
    monkeypatch.setattr("app.main.ACTIVE_PORT_FILE", port_file)

    assert ollama_base_url() == "http://127.0.0.1:12345"
