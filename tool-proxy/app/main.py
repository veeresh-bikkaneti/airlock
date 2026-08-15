"""
tool-proxy: an OpenAI-compatible /v1/chat/completions endpoint that fixes
unreliable tool-calling on local Ollama models.

Why this exists (2026-08-15 investigation, docs/08-Agent-CLI-Setup-Guide.md):
opencode and Pi.dev both drive Ollama's free-form tool-calling path (the
OpenAI "tools" contract, relying on the model's own chat template to emit a
correctly-formatted tool call). On qwen2.5-coder:7b and qwen3-coder:30b that
path fails reproducibly - the model prints the tool call as plain text
instead of a structured call. Confirmed live that this happens even against
Ollama's *native* /api/chat with tools declared, so it isn't an opencode/Pi
bug or an OpenAI-compat translation bug - the model's tool-call template
just isn't firing on this build.

What fixes it: Ollama's `format` parameter does grammar-constrained decoding
- it forces the token sampler itself to only produce output matching a JSON
schema, so the model *cannot* emit malformed output. Tested live: 3/3 clean,
correctly-argued tool calls on the same model that failed via the free-form
path. The catch: constrained decoding only guarantees the shape, not the
decision of whether a tool is needed at all - a schema that only allows a
tool call will fabricate one even for "what is 2+2?". This proxy uses a
router schema (action: call_tool | respond) so the model keeps the choice.

This is a translation layer, not a smarter model. If nothing here matches a
declared tool, or `tools` isn't present in the request, it passes straight
through to Ollama's own OpenAI-compat endpoint unchanged.
"""

import json
import os
import time
import uuid
from pathlib import Path
from typing import Any

import requests
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

app = FastAPI(title="tool-proxy")

ACTIVE_PORT_FILE = Path(os.environ.get("USERPROFILE", "")) / ".ai-platform" / ".active-port.json"
FALLBACK_OLLAMA_PORT = 12345


def ollama_base_url() -> str:
    """Read the live Ollama port fresh on every request.

    Airlock's Start-AI.ps1 adopts whatever port an already-running Ollama is
    on rather than a fixed value (docs/08's whole "port is a snapshot, not a
    stable value" finding). Caching this at proxy startup would just
    reintroduce the same drift bug this proxy exists to route around.
    """
    override = os.environ.get("OLLAMA_BASE_URL")
    if override:
        return override.rstrip("/")
    try:
        state = json.loads(ACTIVE_PORT_FILE.read_text(encoding="utf-8"))
        port = int(state["port"])
    except (OSError, ValueError, KeyError):
        port = FALLBACK_OLLAMA_PORT
    return f"http://127.0.0.1:{port}"


def build_router_schema(tool_names: list[str]) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["call_tool", "respond"]},
            "tool_name": {"type": "string", "enum": tool_names},
            "tool_arguments": {"type": "object"},
            "response_text": {"type": "string"},
        },
        "required": ["action"],
    }


def build_tool_briefing(tools: list[dict[str, Any]]) -> str:
    lines = [
        "You have access to the following tools. If the user's request needs "
        'one of them, set "action" to "call_tool", set "tool_name" to the '
        'exact tool name below, and set "tool_arguments" to a JSON object '
        "with the correct arguments for that tool, matching its parameter "
        'schema. If no tool is needed, set "action" to "respond" and put '
        'your full answer in "response_text".',
        "",
        "Available tools:",
    ]
    for t in tools:
        fn = t.get("function", {})
        name = fn.get("name", "")
        desc = fn.get("description", "")
        params = fn.get("parameters", {})
        lines.append(f"- {name}: {desc}")
        lines.append(f"  parameters schema: {json.dumps(params)}")
    return "\n".join(lines)


def normalize_messages(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Fold OpenAI's tool-call/tool-result message shapes into plain
    role+content turns Ollama's native /api/chat always accepts.

    Ollama's /api/chat rejected a real second-turn request with 400 Bad
    Request the first time this was tested against a live opencode run - it
    does not understand OpenAI's `tool_calls` field on an assistant message
    or a `role: "tool"` result message. Since the model already speaks our
    action/tool_name/tool_arguments/response_text schema (from the system
    briefing), echoing its own prior turns back in that same shape keeps
    multi-turn tool use coherent without depending on Ollama's native
    tool-message schema at all.
    """
    normalized: list[dict[str, Any]] = []
    for m in messages:
        role = m.get("role")
        if role == "assistant" and m.get("tool_calls"):
            call = m["tool_calls"][0]["function"]
            try:
                arguments = json.loads(call.get("arguments", "{}"))
            except json.JSONDecodeError:
                arguments = {}
            content = json.dumps(
                {"action": "call_tool", "tool_name": call.get("name", ""), "tool_arguments": arguments}
            )
            normalized.append({"role": "assistant", "content": content})
        elif role == "tool":
            normalized.append({"role": "user", "content": f"Tool result: {m.get('content', '')}"})
        else:
            normalized.append({"role": role, "content": m.get("content", "")})
    return normalized


def openai_chat_completion(model: str, message: dict[str, Any], finish_reason: str,
                            usage: dict[str, int]) -> dict[str, Any]:
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": usage,
    }


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "upstream": ollama_base_url()}


@app.get("/v1/models")
def models() -> Any:
    resp = requests.get(f"{ollama_base_url()}/v1/models", timeout=10)
    return JSONResponse(status_code=resp.status_code, content=resp.json())


@app.post("/v1/chat/completions")
async def chat_completions(request: Request) -> Any:
    body = await request.json()
    model = body.get("model", "")
    messages = list(body.get("messages", []))
    tools = body.get("tools")
    stream = bool(body.get("stream", False))
    base = ollama_base_url()

    if not tools:
        # No tools declared - nothing for this proxy to fix. Forward as-is
        # to Ollama's own OpenAI-compat endpoint, streaming included.
        upstream = requests.post(
            f"{base}/v1/chat/completions", json=body, stream=stream, timeout=120
        )
        if stream:
            return StreamingResponse(
                upstream.iter_content(chunk_size=None),
                status_code=upstream.status_code,
                media_type=upstream.headers.get("content-type", "text/event-stream"),
            )
        return JSONResponse(status_code=upstream.status_code, content=upstream.json())

    tool_names = [t.get("function", {}).get("name", "") for t in tools]
    briefing = build_tool_briefing(tools)

    routed_messages = [{"role": "system", "content": briefing}] + normalize_messages(messages)

    ollama_payload = {
        "model": model,
        "stream": False,
        "messages": routed_messages,
        "format": build_router_schema(tool_names),
    }
    upstream = requests.post(f"{base}/api/chat", json=ollama_payload, timeout=120)
    if not upstream.ok:
        return JSONResponse(
            status_code=502,
            content={"error": "upstream Ollama rejected the request", "detail": upstream.text},
        )
    result = upstream.json()

    raw_content = result.get("message", {}).get("content", "{}")
    try:
        decision = json.loads(raw_content)
    except json.JSONDecodeError:
        # Grammar-constrained output should always be valid JSON; if it
        # somehow isn't, surface the raw text rather than crashing the caller.
        decision = {"action": "respond", "response_text": raw_content}

    usage = {
        "prompt_tokens": result.get("prompt_eval_count", 0),
        "completion_tokens": result.get("eval_count", 0),
        "total_tokens": result.get("prompt_eval_count", 0) + result.get("eval_count", 0),
    }

    if decision.get("action") == "call_tool" and decision.get("tool_name") in tool_names:
        message = {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": f"call_{uuid.uuid4().hex[:12]}",
                    "type": "function",
                    "function": {
                        "name": decision["tool_name"],
                        "arguments": json.dumps(decision.get("tool_arguments", {})),
                    },
                }
            ],
        }
        finish_reason = "tool_calls"
    else:
        message = {"role": "assistant", "content": decision.get("response_text", "")}
        finish_reason = "stop"

    return JSONResponse(content=openai_chat_completion(model, message, finish_reason, usage))
