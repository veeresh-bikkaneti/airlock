"""Runnable check: proves the xLAM prompt translation logic without a live
llama.cpp - every upstream call is monkeypatched. What this does NOT prove
is model quality (whether xLAM actually picks the right tool) - that's a
live/manual check against running llama.cpp, not something a unit test can assert.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
import requests  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.main import app, build_xlam_prompt, parse_xlam_response, to_openai_response  # noqa: E402


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
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string"}},
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a file's contents",
            "parameters": {
                "type": "object",
                "properties": {"filepath": {"type": "string"}, "encoding": {"type": "string"}},
                "required": ["filepath"],
            },
        },
    },
]


# --- build_xlam_prompt tests ---


def test_build_xlam_prompt_single_user_turn():
    """Verify the prompt structure for a simple user query with no tools."""
    prompt = build_xlam_prompt([{"role": "user", "content": "list files in /tmp"}], [])
    assert "[BEGIN OF TASK INSTRUCTION]" in prompt
    assert "[END OF TASK INSTRUCTION]" in prompt
    assert "[BEGIN OF AVAILABLE TOOLS]" in prompt
    assert "[END OF AVAILABLE TOOLS]" in prompt
    assert "[BEGIN OF FORMAT INSTRUCTION]" in prompt
    assert "[END OF FORMAT INSTRUCTION]" in prompt
    assert "[BEGIN OF QUERY]" in prompt
    assert "[END OF QUERY]" in prompt
    assert "user: list files in /tmp" in prompt


def test_build_xlam_prompt_ends_with_trailing_newline():
    """Regression test: a prompt ending exactly at "[END OF QUERY]" with no
    trailing newline made xLAM immediately emit EOS with zero content on a
    real post-tool-failure prompt, live-verified reproducible every time;
    the identical prompt with only a trailing newline appended produced the
    correct recovery. build_xlam_prompt must always end with "\n".
    """
    prompt = build_xlam_prompt([{"role": "user", "content": "hi"}], [])
    assert prompt.endswith("[END OF QUERY]\n")


def test_build_xlam_prompt_tool_flattening():
    """Verify tools are flattened: "properties"/"type":"object" wrapper removed,
    "required" field inlined into each arg's dict.
    """
    prompt = build_xlam_prompt([{"role": "user", "content": "hi"}], TOOLS[:1])
    # Extract the tools JSON block
    start = prompt.find("[BEGIN OF AVAILABLE TOOLS]") + len("[BEGIN OF AVAILABLE TOOLS]")
    end = prompt.find("[END OF AVAILABLE TOOLS]")
    tools_block = prompt[start:end].strip()
    tools_json = json.loads(tools_block)

    assert len(tools_json) == 1
    tool = tools_json[0]
    assert tool["name"] == "list_files"
    assert "description" in tool
    params = tool["parameters"]
    assert "path" in params
    # Verify "required" is inlined into the arg's dict
    assert params["path"]["required"] is True
    # Verify no "properties"/"type":"object" wrapper at top level
    assert "properties" not in params
    assert "type" not in params


def test_build_xlam_prompt_multi_arg_with_mixed_required():
    """Verify that required status is correctly assigned to each argument."""
    prompt = build_xlam_prompt([{"role": "user", "content": "hi"}], TOOLS[1:2])  # read_file has filepath+encoding
    start = prompt.find("[BEGIN OF AVAILABLE TOOLS]") + len("[BEGIN OF AVAILABLE TOOLS]")
    end = prompt.find("[END OF AVAILABLE TOOLS]")
    tools_block = prompt[start:end].strip()
    tools_json = json.loads(tools_block)

    tool = tools_json[0]
    params = tool["parameters"]
    assert params["filepath"]["required"] is True  # in required list
    assert params["encoding"]["required"] is False  # not in required list


def test_build_xlam_prompt_malformed_tool_skipped():
    """Verify that malformed tools (missing name) are skipped, not crashing."""
    bad_tools = [
        {"type": "function", "function": {"description": "No name field"}},
        {"type": "function", "function": {"name": "good_one", "description": "Good"}},
    ]
    prompt = build_xlam_prompt([{"role": "user", "content": "hi"}], bad_tools)
    start = prompt.find("[BEGIN OF AVAILABLE TOOLS]") + len("[BEGIN OF AVAILABLE TOOLS]")
    end = prompt.find("[END OF AVAILABLE TOOLS]")
    tools_block = prompt[start:end].strip()
    tools_json = json.loads(tools_block)

    assert len(tools_json) == 1
    assert tools_json[0]["name"] == "good_one"


def test_build_xlam_prompt_system_message_skipped():
    """Verify system messages are skipped (already in fixed task instruction)."""
    prompt = build_xlam_prompt(
        [
            {"role": "system", "content": "You are an AI assistant."},
            {"role": "user", "content": "hi"},
        ],
        [],
    )
    # System content should NOT appear in the query block
    query_start = prompt.find("[BEGIN OF QUERY]")
    query_end = prompt.find("[END OF QUERY]")
    query_block = prompt[query_start:query_end]
    assert "You are an AI assistant" not in query_block
    assert "user: hi" in query_block


def test_build_xlam_prompt_multi_turn_folds_as_single_narrated_turn():
    """Verify history folds as one person's continuous narration, not a
    "user:"/"assistant:" labeled dialogue transcript.

    Live-verified this matters, not just style: xLAM's chat_template_caps
    report supports_tools=False/supports_tool_calls=False - it has no
    native multi-turn dialogue-role concept. A role-labeled transcript
    (the shape this file originally used, mirroring tool-proxy's own
    normalize_messages) reads to xLAM as an already-concluded conversation:
    reproducible on a real captured post-tool-failure prompt, the model
    immediately emitted EOS with zero content, every time, at every
    temperature 0-0.5 - even though a correct recovery demonstrably existed
    in its output distribution. Folding the identical information as one
    continuous narration ("I called X with Y. It returned: Z.") instead of
    labeled turns immediately produced the correct recovery.
    """
    prompt = build_xlam_prompt(
        [
            {"role": "user", "content": "list files in /tmp"},
            {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": "list_files", "arguments": '{"path": "/tmp"}'},
                    }
                ],
            },
            {"role": "tool", "tool_call_id": "call_1", "content": "file1.txt, file2.txt"},
        ],
        [],
    )
    query_start = prompt.find("[BEGIN OF QUERY]")
    query_end = prompt.find("[END OF QUERY]")
    query_block = prompt[query_start:query_end]

    # No dialogue-role labels anywhere past the first line - this is the
    # specific regression that must never come back.
    assert "assistant:" not in query_block
    assert "tool result for" not in query_block

    # The call and its result fold into one narrated sentence, attributed
    # to the right call via tool_call_id.
    assert "I called list_files with" in query_block
    assert '"path": "/tmp"' in query_block
    assert "It returned: file1.txt, file2.txt" in query_block
    # A forward-looking closer follows any tool activity, generic enough
    # to make sense after either a failure or a success.
    assert "Continue completing the original task." in query_block


def test_build_xlam_prompt_tool_result_attributed_to_call_id():
    """Verify a tool result is paired with the specific call that produced
    it (by tool_call_id), not just the most recent call, when multiple
    calls are in flight.
    """
    prompt = build_xlam_prompt(
        [
            {"role": "user", "content": "hi"},
            {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {"id": "call_1", "type": "function", "function": {"name": "read", "arguments": "{}"}},
                    {"id": "call_2", "type": "function", "function": {"name": "write", "arguments": "{}"}},
                ],
            },
            {"role": "tool", "tool_call_id": "call_2", "content": "write failed"},
            {"role": "tool", "tool_call_id": "call_1", "content": "read succeeded"},
        ],
        [],
    )
    query_start = prompt.find("[BEGIN OF QUERY]")
    query_end = prompt.find("[END OF QUERY]")
    query_block = prompt[query_start:query_end]

    assert "I called write with {}. It returned: write failed" in query_block
    assert "I called read with {}. It returned: read succeeded" in query_block


# --- parse_xlam_response tests ---


def test_parse_xlam_response_valid_json():
    """Verify parsing of valid JSON tool_calls."""
    raw = json.dumps({"tool_calls": [{"name": "list_files", "arguments": {"path": "."}}]})
    result = parse_xlam_response(raw)
    assert result["tool_calls"] == [{"name": "list_files", "arguments": {"path": "."}}]


def test_parse_xlam_response_with_thought_field():
    """Verify that optional "thought" field is preserved in parsed output."""
    raw = json.dumps(
        {
            "thought": "User wants to list files in the current directory.",
            "tool_calls": [{"name": "list_files", "arguments": {"path": "."}}],
        }
    )
    result = parse_xlam_response(raw)
    assert result["thought"] == "User wants to list files in the current directory."
    assert result["tool_calls"] == [{"name": "list_files", "arguments": {"path": "."}}]


def test_parse_xlam_response_markdown_json_fenced():
    """Verify markdown-wrapped JSON is stripped and parsed."""
    raw = """```json
{"tool_calls": [{"name": "list_files", "arguments": {"path": "."}}]}
```"""
    result = parse_xlam_response(raw)
    assert result["tool_calls"] == [{"name": "list_files", "arguments": {"path": "."}}]


def test_parse_xlam_response_markdown_plain_fenced():
    """Verify plain markdown fences (no language tag) are stripped."""
    raw = """```
{"tool_calls": []}
```"""
    result = parse_xlam_response(raw)
    assert result["tool_calls"] == []


def test_parse_xlam_response_malformed_json_fallback():
    """Verify malformed JSON returns safe fallback with content field."""
    raw = "not json at all"
    result = parse_xlam_response(raw)
    assert result["tool_calls"] == []
    assert result["content"] == "not json at all"


def test_parse_xlam_response_json_missing_tool_calls_key_fallback():
    """Verify JSON without tool_calls key returns fallback."""
    raw = json.dumps({"some_other_field": "value"})
    result = parse_xlam_response(raw)
    assert result["tool_calls"] == []
    assert result["content"] == raw


# --- to_openai_response tests ---


def test_to_openai_response_tool_calls():
    """Verify tool_calls shape is correctly built."""
    decision = {"tool_calls": [{"name": "list_files", "arguments": {"path": "."}}]}
    message = to_openai_response(decision, "raw")
    assert message["role"] == "assistant"
    assert message["content"] is None
    assert len(message["tool_calls"]) == 1
    call = message["tool_calls"][0]
    assert call["type"] == "function"
    assert call["function"]["name"] == "list_files"
    assert json.loads(call["function"]["arguments"]) == {"path": "."}
    assert "id" in call
    assert call["id"].startswith("call_")


def test_to_openai_response_plain_content():
    """Verify plain content shape when no tool_calls."""
    decision = {"content": "4"}
    message = to_openai_response(decision, "raw")
    assert message["role"] == "assistant"
    assert message["content"] == "4"
    assert "tool_calls" not in message


def test_to_openai_response_fallback_to_raw_text():
    """Verify fallback to raw_text when decision has neither tool_calls nor content."""
    decision = {}
    message = to_openai_response(decision, "some raw text")
    assert message["content"] == "some raw text"


def test_to_openai_response_malformed_tool_call_skipped():
    """Verify malformed tool_calls (missing name) are skipped."""
    decision = {
        "tool_calls": [
            {"arguments": {"path": "."}},  # Missing name
            {"name": "list_files", "arguments": {"path": "."}},  # Valid
        ]
    }
    message = to_openai_response(decision, "raw")
    assert len(message["tool_calls"]) == 1
    assert message["tool_calls"][0]["function"]["name"] == "list_files"


# --- Route handler tests ---


def test_health_endpoint_when_llama_running(client, monkeypatch, tmp_path):
    """Verify /health returns ok and base url when llama port file exists."""
    port_file = tmp_path / "llamacpp-instance.json"
    port_file.write_text(json.dumps({"port": 8000}))
    monkeypatch.setattr("app.main.LLAMACPP_INSTANCE_FILE", port_file)

    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert "8000" in body["upstream"]


def test_health_endpoint_when_llama_not_running(client, monkeypatch, tmp_path):
    """Verify /health returns unavailable when port file missing."""
    port_file = tmp_path / "llamacpp-instance.json"
    monkeypatch.setattr("app.main.LLAMACPP_INSTANCE_FILE", port_file)

    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["upstream"] == "unavailable"


def test_chat_completions_missing_llama_returns_502(client, monkeypatch, tmp_path):
    """Verify 502 when llama port file missing."""
    port_file = tmp_path / "llamacpp-instance.json"
    monkeypatch.setattr("app.main.LLAMACPP_INSTANCE_FILE", port_file)

    resp = client.post("/v1/chat/completions", json={"model": "xLAM", "messages": [{"role": "user", "content": "hi"}]})
    assert resp.status_code == 502
    body = resp.json()
    assert "error" in body
    assert "detail" in body


def test_chat_completions_invalid_json_body_returns_400(client):
    """Verify 400 on invalid JSON."""
    resp = client.post("/v1/chat/completions", content=b"not json", headers={"content-type": "application/json"})
    assert resp.status_code == 400


def test_chat_completions_non_dict_body_returns_400(client):
    """Verify 400 when body is not a dict."""
    resp = client.post("/v1/chat/completions", json=[1, 2, 3])
    assert resp.status_code == 400


def test_chat_completions_non_dict_messages_entry_returns_400(client, monkeypatch, tmp_path):
    """Verify 400 when a message entry is not a dict."""
    port_file = tmp_path / "llamacpp-instance.json"
    port_file.write_text(json.dumps({"port": 8000}))
    monkeypatch.setattr("app.main.Path", lambda *args: port_file if "llamacpp" in str(args) else Path(*args))

    resp = client.post(
        "/v1/chat/completions",
        json={"model": "xLAM", "messages": [None]},
    )
    assert resp.status_code == 400


def test_chat_completions_upstream_connection_error_returns_502(client, monkeypatch, tmp_path):
    """Verify 502 when upstream connection fails."""
    port_file = tmp_path / "llamacpp-instance.json"
    port_file.write_text(json.dumps({"port": 8000}))
    monkeypatch.setattr("app.main.LLAMACPP_INSTANCE_FILE", port_file)

    def fake_post(url, json=None, timeout=None):
        raise requests.exceptions.ConnectionError("Connection refused")

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post("/v1/chat/completions", json={"model": "xLAM", "messages": [{"role": "user", "content": "hi"}]})
    assert resp.status_code == 502
    assert "unreachable" in resp.json()["error"]


def test_chat_completions_upstream_non_ok_returns_502(client, monkeypatch, tmp_path):
    """Verify 502 when upstream returns non-2xx."""
    port_file = tmp_path / "llamacpp-instance.json"
    port_file.write_text(json.dumps({"port": 8000}))
    monkeypatch.setattr("app.main.LLAMACPP_INSTANCE_FILE", port_file)

    def fake_post(url, json=None, timeout=None):
        return FakeResponse(status_code=500, text="model not found")

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post("/v1/chat/completions", json={"model": "xLAM", "messages": [{"role": "user", "content": "hi"}]})
    assert resp.status_code == 502
    assert "rejected the request" in resp.json()["error"]


def test_chat_completions_upstream_unparseable_json_returns_502(client, monkeypatch, tmp_path):
    """Verify 502 when upstream returns non-JSON."""
    port_file = tmp_path / "llamacpp-instance.json"
    port_file.write_text(json.dumps({"port": 8000}))
    monkeypatch.setattr("app.main.LLAMACPP_INSTANCE_FILE", port_file)

    class BadJsonResponse:
        status_code = 200
        ok = True
        text = "not json"

        def json(self):
            raise json.JSONDecodeError("Expecting value", "not json", 0)

    def fake_post(url, json=None, timeout=None):
        return BadJsonResponse()

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post("/v1/chat/completions", json={"model": "xLAM", "messages": [{"role": "user", "content": "hi"}]})
    assert resp.status_code == 502
    assert "unparseable" in resp.json()["error"]


def test_chat_completions_end_to_end_tool_call(client, monkeypatch, tmp_path):
    """Full end-to-end test: request → prompt build → llama call → parse → response."""
    port_file = tmp_path / "llamacpp-instance.json"
    port_file.write_text(json.dumps({"port": 8000}))
    monkeypatch.setattr("app.main.LLAMACPP_INSTANCE_FILE", port_file)

    llama_response = {
        "content": json.dumps(
            {"tool_calls": [{"name": "list_files", "arguments": {"path": "."}}]}
        )
    }

    def fake_post(url, json=None, timeout=None):
        # Verify the prompt was built
        assert json is not None
        prompt = json.get("prompt")
        assert prompt is not None
        assert "[BEGIN OF TASK INSTRUCTION]" in prompt
        assert "list_files" in prompt
        return FakeResponse(json_body=llama_response)

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "xLAM",
            "messages": [{"role": "user", "content": "list files"}],
            "tools": TOOLS[:1],
        },
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["object"] == "chat.completion"
    message = body["choices"][0]["message"]
    assert message["role"] == "assistant"
    assert message["content"] is None
    assert len(message["tool_calls"]) == 1
    assert message["tool_calls"][0]["function"]["name"] == "list_files"
    assert body["choices"][0]["finish_reason"] == "tool_calls"


def test_chat_completions_end_to_end_no_tool_call(client, monkeypatch, tmp_path):
    """Full end-to-end test when no tool call is needed."""
    port_file = tmp_path / "llamacpp-instance.json"
    port_file.write_text(json.dumps({"port": 8000}))
    monkeypatch.setattr("app.main.LLAMACPP_INSTANCE_FILE", port_file)

    llama_response = {"content": json.dumps({"tool_calls": []})}

    def fake_post(url, json=None, timeout=None):
        return FakeResponse(json_body=llama_response)

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "xLAM",
            "messages": [{"role": "user", "content": "what is 2+2?"}],
            "tools": TOOLS[:1],
        },
    )

    assert resp.status_code == 200
    body = resp.json()
    message = body["choices"][0]["message"]
    assert message["role"] == "assistant"
    # When decision has tool_calls=[] (empty list), content is the raw response
    assert message["content"] == json.dumps({"tool_calls": []})
    assert body["choices"][0]["finish_reason"] == "stop"


def test_chat_completions_stream_true_returns_sse(client, monkeypatch, tmp_path):
    """Verify SSE response when stream=True."""
    port_file = tmp_path / "llamacpp-instance.json"
    port_file.write_text(json.dumps({"port": 8000}))
    monkeypatch.setattr("app.main.LLAMACPP_INSTANCE_FILE", port_file)

    llama_response = {"content": json.dumps({"tool_calls": [{"name": "list_files", "arguments": {"path": "."}}]})}

    def fake_post(url, json=None, timeout=None):
        return FakeResponse(json_body=llama_response)

    monkeypatch.setattr("app.main.requests.post", fake_post)

    resp = client.post(
        "/v1/chat/completions",
        json={
            "model": "xLAM",
            "messages": [{"role": "user", "content": "hi"}],
            "tools": TOOLS[:1],
            "stream": True,
        },
    )

    assert resp.status_code == 200
    assert "text/event-stream" in resp.headers["content-type"]
    text = resp.text
    assert text.startswith("data: ")
    assert "[DONE]" in text
