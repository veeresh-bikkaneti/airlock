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
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import JSONResponse, StreamingResponse

app = FastAPI(title="tool-proxy")

ACTIVE_PORT_FILE = Path(os.environ.get("USERPROFILE", "")) / ".ai-platform" / ".active-port.json"
ACTIVE_PROVIDER_FILE = Path(os.environ.get("USERPROFILE", "")) / ".ai-platform" / "state" / "active-provider.json"
FALLBACK_OLLAMA_PORT = 12345


def active_provider() -> str:
    """Which backend Start-AI.ps1/Start-VLLM.ps1 last selected ("ollama" or
    "vllm"), read fresh on every request for the same reason as
    ollama_base_url(). Defaults to "ollama" - the grammar-constrained /api/chat
    path only exists there; vLLM has no equivalent route.
    """
    try:
        state = json.loads(ACTIVE_PROVIDER_FILE.read_text(encoding="utf-8"))
        return str(state.get("provider", "ollama"))
    except (OSError, ValueError, KeyError):
        return "ollama"


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
    except (OSError, ValueError, KeyError, TypeError):
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


def inject_tool_briefing(messages: list[dict[str, Any]], briefing: str) -> list[dict[str, Any]]:
    """Merge the tool briefing into an existing leading system message rather
    than prepending a second one. Ollama tolerates multiple system messages,
    but smaller models can ignore or garble the second one - and it doubles
    the system-prompt token count for no reason either way.
    """
    if messages and messages[0].get("role") == "system":
        merged = dict(messages[0])
        merged["content"] = f"{merged.get('content', '')}\n\n{briefing}"
        return [merged] + messages[1:]
    return [{"role": "system", "content": briefing}] + messages


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
            call = m["tool_calls"][0].get("function", {})
            raw_arguments = call.get("arguments", "{}")
            if isinstance(raw_arguments, str):
                try:
                    arguments = json.loads(raw_arguments)
                except json.JSONDecodeError:
                    arguments = {}
            else:
                # Spec-violating but seen in the wild: some clients send the
                # already-decoded object instead of a JSON-encoded string.
                arguments = raw_arguments if isinstance(raw_arguments, dict) else {}
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


def sse_chunk_response(model: str, message: dict[str, Any], finish_reason: str) -> StreamingResponse:
    """Grammar-constrained decoding produces one short JSON object, not token-
    by-token output, so there's nothing to genuinely stream. Emit the whole
    result as a single SSE chunk instead - correct framing for SSE-expecting
    clients (opencode, Pi.dev) without pretending to stream tokens that were
    never generated incrementally in the first place.
    """
    chunk = {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "delta": message, "finish_reason": finish_reason}],
    }

    def emit():
        yield f"data: {json.dumps(chunk)}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(emit(), media_type="text/event-stream")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "upstream": ollama_base_url()}


@app.get("/v1/models")
def models() -> Any:
    try:
        resp = requests.get(f"{ollama_base_url()}/v1/models", timeout=10)
    except requests.exceptions.RequestException as exc:
        return JSONResponse(status_code=502, content={"error": "upstream unreachable", "detail": str(exc)})
    try:
        content = resp.json()
    except json.JSONDecodeError:
        return JSONResponse(
            status_code=502, content={"error": "upstream returned an unparseable body", "detail": resp.text}
        )
    return JSONResponse(status_code=resp.status_code, content=content)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request) -> Any:
    body = await request.json()
    if not isinstance(body, dict):
        return JSONResponse(status_code=400, content={"error": "request body must be a JSON object"})
    model = body.get("model", "")
    messages = list(body.get("messages") or [])
    tools = body.get("tools")
    stream = bool(body.get("stream", False))
    base = ollama_base_url()

    if not tools:
        # No tools declared - nothing for this proxy to fix. Forward as-is
        # to Ollama's own OpenAI-compat endpoint, streaming included.
        try:
            upstream = await run_in_threadpool(
                requests.post, f"{base}/v1/chat/completions", json=body, stream=stream, timeout=120
            )
        except requests.exceptions.RequestException as exc:
            return JSONResponse(status_code=502, content={"error": "upstream unreachable", "detail": str(exc)})
        if stream:
            return StreamingResponse(
                upstream.iter_content(chunk_size=None),
                status_code=upstream.status_code,
                media_type=upstream.headers.get("content-type", "text/event-stream"),
            )
        return JSONResponse(status_code=upstream.status_code, content=upstream.json())

    if active_provider() == "vllm":
        # vLLM has no /api/chat route and no `format` grammar parameter - the
        # Ollama-only path below would always 502. Pass the request straight
        # through to vLLM's own OpenAI-compatible tool-calling instead.
        # Whether vLLM actually resolves tool calls reliably is unverified
        # here (Start-VLLM.ps1 doesn't currently pass --enable-auto-tool-choice)
        # - this just stops guaranteeing a failure, it isn't a fix for that.
        try:
            upstream = await run_in_threadpool(
                requests.post, f"{base}/v1/chat/completions", json=body, stream=stream, timeout=120
            )
        except requests.exceptions.RequestException as exc:
            return JSONResponse(status_code=502, content={"error": "upstream unreachable", "detail": str(exc)})
        if stream:
            return StreamingResponse(
                upstream.iter_content(chunk_size=None),
                status_code=upstream.status_code,
                media_type=upstream.headers.get("content-type", "text/event-stream"),
            )
        try:
            content = upstream.json()
        except json.JSONDecodeError:
            return JSONResponse(
                status_code=502,
                content={"error": "upstream returned an unparseable body", "detail": upstream.text},
            )
        return JSONResponse(status_code=upstream.status_code, content=content)

    valid_tools = [
        t for t in tools
        if isinstance(t, dict) and isinstance(t.get("function"), dict) and t["function"].get("name")
    ]
    tool_names = [t["function"]["name"] for t in valid_tools]
    briefing = build_tool_briefing(valid_tools)

    routed_messages = inject_tool_briefing(normalize_messages(messages), briefing)

    ollama_payload = {
        "model": model,
        "stream": False,
        "messages": routed_messages,
        "format": build_router_schema(tool_names),
    }
    try:
        upstream = await run_in_threadpool(requests.post, f"{base}/api/chat", json=ollama_payload, timeout=120)
    except requests.exceptions.RequestException as exc:
        return JSONResponse(status_code=502, content={"error": "upstream unreachable", "detail": str(exc)})
    if not upstream.ok:
        return JSONResponse(
            status_code=502,
            content={"error": "upstream Ollama rejected the request", "detail": upstream.text},
        )
    try:
        result = upstream.json()
    except json.JSONDecodeError:
        return JSONResponse(
            status_code=502,
            content={"error": "upstream Ollama returned an unparseable body", "detail": upstream.text},
        )

    raw_content = (result.get("message") or {}).get("content") or "{}"
    try:
        decision = json.loads(raw_content)
    except json.JSONDecodeError:
        # Grammar-constrained output should always be valid JSON; if it
        # somehow isn't, surface the raw text rather than crashing the caller.
        decision = {"action": "respond", "response_text": raw_content}

    prompt_tokens = result.get("prompt_eval_count") or 0
    completion_tokens = result.get("eval_count") or 0
    usage = {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": prompt_tokens + completion_tokens,
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

    if stream:
        return sse_chunk_response(model, message, finish_reason)
    return JSONResponse(content=openai_chat_completion(model, message, finish_reason, usage))
