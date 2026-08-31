"""
xlam-proxy: an OpenAI-compatible /v1/chat/completions endpoint that translates
requests into Salesforce xLAM-7b-fc-r's native prompt format.

xLAM is a specialized model fine-tuned on function-calling tasks. Unlike
general-purpose models, it uses a fixed four-block prompt structure and expects
output as a JSON object matching its specific schema. This proxy translates
OpenAI-shaped requests into xLAM's format and back, so generic clients
(opencode, Pi.dev, etc.) can use xLAM through llama.cpp's raw /completion
endpoint without knowing its quirks.
"""

import json
import os
import re
import time
import uuid
from pathlib import Path
from typing import Any

import requests
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

app = FastAPI(title="xlam-proxy")

LLAMACPP_INSTANCE_FILE = Path(os.environ.get("USERPROFILE", "")) / ".ai-platform" / "state" / "llamacpp-instance.json"


def llama_base_url() -> str | None:
    """Read the live llama.cpp port fresh on every request from
    state/llamacpp-instance.json. Returns None if the file is missing,
    unparseable, or has no port field - the caller must 502 on None,
    since this runtime has no fixed default port like Ollama's 11434.
    """
    try:
        state = json.loads(LLAMACPP_INSTANCE_FILE.read_text(encoding="utf-8"))
        port = state.get("port")
        if port is None or not isinstance(port, int):
            return None
        return f"http://127.0.0.1:{port}"
    except (OSError, ValueError, KeyError, TypeError):
        return None


def build_xlam_prompt(messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> str:
    """Render Salesforce's exact four-block xLAM prompt format.

    Tool flattening: OpenAI's nested shape
    {"type": "function", "function": {"name", "description", "parameters": {"type": "object", "properties": {...}}}}
    becomes xLAM's flat shape
    {"name": ..., "description": ..., "parameters": {argname: {..., "required": true/false}, ...}}
    """
    # Flatten tools: drop "type" and "function" wrapper, inline "required" into each arg's dict
    flattened_tools = []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        fn = tool.get("function")
        if not isinstance(fn, dict) or not fn.get("name"):
            continue  # Skip malformed entries
        name = fn["name"]
        description = fn.get("description", "")
        params_spec = fn.get("parameters", {})
        properties = params_spec.get("properties", {})
        required_list = params_spec.get("required", [])

        flattened_params = {}
        for arg_name, arg_spec in properties.items():
            arg_flat = dict(arg_spec)
            arg_flat["required"] = arg_name in required_list
            flattened_params[arg_name] = arg_flat

        flattened_tools.append({"name": name, "description": description, "parameters": flattened_params})

    # Build the four-block prompt
    lines = [
        "[BEGIN OF TASK INSTRUCTION]",
        "You are an expert in composing functions. You are given a question and a set of possible functions.",
        "Based on the question, you will need to make one or more function/tool calls to achieve the purpose.",
        "If none of the functions can be used, point it out. If the given question lacks the parameters required by the function, also point it out.",
        "[END OF TASK INSTRUCTION]",
        "",
        "[BEGIN OF AVAILABLE TOOLS]",
        json.dumps(flattened_tools),
        "[END OF AVAILABLE TOOLS]",
        "",
        "[BEGIN OF FORMAT INSTRUCTION]",
        "The output MUST strictly adhere to the following JSON format, and NO other text MUST be included.",
        "The example format is as follows. Please make sure the parameter type is correct. If no function call is needed, please make tool_calls an empty list '[]'.",
        '{"tool_calls": [{"name": "func_name1", "arguments": {"argument1": "value1", "argument2": "value2"}}]}',
        "[END OF FORMAT INSTRUCTION]",
        "",
    ]

    # Fold conversation: walk messages in order, building the query block
    call_names: dict[str, str] = {}  # tool_call_id -> function_name for attribution
    query_lines = []

    for m in messages:
        role = m.get("role")
        if role == "system":
            # Skip system messages - already covered by fixed task instruction
            continue
        elif role == "user":
            query_lines.append(f"user: {m.get('content', '')}")
        elif role == "assistant":
            if m.get("tool_calls"):
                # Re-serialize tool_calls as xLAM-shaped JSON
                calls = []
                for tc in m.get("tool_calls", []):
                    if not isinstance(tc, dict):
                        continue
                    fn = tc.get("function", {})
                    if not isinstance(fn, dict):
                        continue
                    name = fn.get("name")
                    args_str = fn.get("arguments", "{}")
                    try:
                        if isinstance(args_str, str):
                            arguments = json.loads(args_str)
                        else:
                            arguments = args_str if isinstance(args_str, dict) else {}
                    except json.JSONDecodeError:
                        arguments = {}
                    calls.append({"name": name, "arguments": arguments})
                    call_id = tc.get("id")
                    if call_id:
                        call_names[call_id] = name
                if calls:
                    query_lines.append(f"assistant: {json.dumps({'tool_calls': calls})}")
            elif m.get("content"):
                query_lines.append(f"assistant: {m['content']}")
        elif role == "tool":
            call_id = m.get("tool_call_id")
            name = call_names.get(call_id, "") if call_id else ""
            label = f"{name} ({call_id})" if name else (call_id or "unknown call")
            query_lines.append(f"tool result for {label}: {m.get('content', '')}")

    lines.append("[BEGIN OF QUERY]")
    lines.extend(query_lines)
    lines.append("[END OF QUERY]")

    return "\n".join(lines)


def call_llama_completion(base_url: str, prompt: str) -> str:
    """Call llama.cpp's /completion endpoint with hard-coded temperature=0,
    n_predict=512 (xLAM's output is a short JSON blob, not token-streamable).
    Returns the generated text on success.

    Three-tier error handling:
    - requests.exceptions.RequestException → raise
    - Non-2xx response → raise with upstream body detail
    - Unparseable JSON response → raise with raw text
    """
    try:
        resp = requests.post(
            f"{base_url}/completion",
            json={"prompt": prompt, "temperature": 0, "n_predict": 512},
            timeout=60,
        )
    except requests.exceptions.RequestException as exc:
        raise exc

    if not resp.ok:
        raise RuntimeError(f"upstream llama-server rejected the request: {resp.text}")

    try:
        result = resp.json()
    except json.JSONDecodeError:
        raise RuntimeError(f"upstream llama-server returned an unparseable body: {resp.text}")

    return result.get("content", "")


def parse_xlam_response(raw_text: str) -> dict[str, Any]:
    """Extract the {"tool_calls": [...]} JSON object from raw_text.
    Strip markdown fences if present. Tolerate an optional "thought" field.
    On any parse failure, return {"tool_calls": [], "content": raw_text} as fallback.
    """
    # Strip markdown code fences
    text = raw_text
    if text.startswith("```json"):
        text = text[7:]
    elif text.startswith("```"):
        text = text[3:]
    if text.endswith("```"):
        text = text[:-3]
    text = text.strip()

    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict) and "tool_calls" in parsed:
            return parsed
    except json.JSONDecodeError:
        pass

    return {"tool_calls": [], "content": raw_text}


def to_openai_response(decision: dict[str, Any], raw_text: str) -> dict[str, Any]:
    """Build the OpenAI-shaped message object from the parsed decision.
    If decision has tool_calls, build the tool-call shape; otherwise content shape.
    """
    tool_calls_list = decision.get("tool_calls", [])
    if tool_calls_list and isinstance(tool_calls_list, list):
        tool_calls = []
        for tc in tool_calls_list:
            if not isinstance(tc, dict) or not tc.get("name"):
                continue  # Skip malformed entries
            tool_calls.append(
                {
                    "id": f"call_{uuid.uuid4().hex[:12]}",
                    "type": "function",
                    "function": {"name": tc["name"], "arguments": json.dumps(tc.get("arguments", {}))},
                }
            )
        if tool_calls:
            return {"role": "assistant", "content": None, "tool_calls": tool_calls}

    return {"role": "assistant", "content": decision.get("content", raw_text)}


def openai_chat_completion(model: str, message: dict[str, Any], finish_reason: str) -> dict[str, Any]:
    """Build the full OpenAI chat.completion envelope."""
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


def sse_chunk_response(model: str, message: dict[str, Any], finish_reason: str) -> StreamingResponse:
    """xLAM's output is a short JSON blob, not token-streamable. Emit the whole
    result as a single SSE chunk for SSE-expecting clients.
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
    base = llama_base_url()
    status = "ok" if base else "unavailable"
    return {"status": status, "upstream": base or "unavailable"}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request) -> Any:
    try:
        body = await request.json()
    except json.JSONDecodeError:
        return JSONResponse(status_code=400, content={"error": "request body is not valid JSON"})

    if not isinstance(body, dict):
        return JSONResponse(status_code=400, content={"error": "request body must be a JSON object"})

    model = body.get("model", "")
    messages = list(body.get("messages") or [])
    if any(not isinstance(m, dict) for m in messages):
        return JSONResponse(status_code=400, content={"error": "every entry in messages must be an object"})

    tools = list(body.get("tools") or [])
    stream = bool(body.get("stream", False))

    base = llama_base_url()
    if base is None:
        return JSONResponse(
            status_code=502,
            content={"error": "llama-server not running", "detail": "state/llamacpp-instance.json not found or has no port"},
        )

    prompt = build_xlam_prompt(messages, tools)

    try:
        raw_text = call_llama_completion(base, prompt)
    except requests.exceptions.RequestException as exc:
        return JSONResponse(status_code=502, content={"error": "upstream unreachable", "detail": str(exc)})
    except RuntimeError as exc:
        detail = str(exc)
        if "rejected the request" in detail:
            return JSONResponse(
                status_code=502, content={"error": "upstream llama-server rejected the request", "detail": detail}
            )
        elif "unparseable" in detail:
            return JSONResponse(status_code=502, content={"error": "upstream llama-server returned an unparseable body", "detail": detail})
        return JSONResponse(status_code=502, content={"error": "upstream error", "detail": detail})

    decision = parse_xlam_response(raw_text)
    message = to_openai_response(decision, raw_text)

    # Determine finish_reason based on whether tool_calls are present
    finish_reason = "tool_calls" if message.get("tool_calls") else "stop"

    if stream:
        return sse_chunk_response(model, message, finish_reason)
    return JSONResponse(content=openai_chat_completion(model, message, finish_reason))
