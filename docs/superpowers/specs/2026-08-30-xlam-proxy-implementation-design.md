# xlam-proxy implementation design

Status: approved architecture, not yet implemented. Resume point for building
ADR-013 (`docs/adr/ADR-013-llama-cpp-xlam-tool-calling-adapter.md`).

Decisions locked in during design review (all "recommended" options chosen):
- Full ADR-012 integration (new runtime + profile + Start-AgentSession.ps1 wiring),
  not a standalone manually-wired service.
- New distinct runtime name `xlam-proxy`, not reusing `llama-server` — the proxy
  bypasses llama-server's embedded chat_template entirely (hardcodes xLAM's own
  known-correct native prompt format instead of trusting `--jinja` rendering), so
  it has a different trust model than raw llama-server usage and shouldn't share
  the existing `Resolve-LlamaCppTemplateVerification` marker-allowlist guarantee.
- Stateless: re-derive the full xLAM prompt from the incoming `messages` array on
  every request. No server-side session store. Matches `tool-proxy`'s own
  convention (`normalize_messages` re-derives everything per call).
- New top-level directory `xlam-proxy/`, not a third branch inside
  `tool-proxy/app/main.py`. Keeps xLAM's prompt-templating logic fully separate
  from Ollama's grammar-constrained-JSON logic.

## 1. `xlam-proxy/` (new top-level directory, mirrors `tool-proxy/`)

```
xlam-proxy/
  app/
    __init__.py
    main.py
  tests/
    test_main.py
  requirements.txt
```

`app/main.py` — FastAPI app, single real route:

- `GET /health`
- `POST /v1/chat/completions` — the only route opencode calls.

Core functions (decomposed the way `tool-proxy/app/main.py` decomposes its own
pipeline — each transformation step is its own top-level function, testable in
isolation):

- `llama_base_url()` — reads `state/llamacpp-instance.json`'s `port` field fresh
  on every request (never cached), same convention as `tool-proxy`'s
  `ollama_base_url()`. Fallback: `None` → 502 if llama-server isn't recorded as
  running.
- `build_xlam_prompt(messages, tools) -> str` — renders Salesforce's four-block
  format:
  - `[BEGIN OF TASK INSTRUCTION]` ... `[END OF TASK INSTRUCTION]` — fixed text
    from the xLAM model card.
  - `[BEGIN OF AVAILABLE TOOLS]` ... `[END OF AVAILABLE TOOLS]` — `tools`
    flattened from OpenAI's nested `function.parameters.properties` shape into
    xLAM's flat `{"name", "description", "parameters": {argname: {...}}}` shape
    (no "properties" wrapper, no "type": "object" wrapper around parameters).
  - `[BEGIN OF FORMAT INSTRUCTION]` ... `[END OF FORMAT INSTRUCTION]` — fixed
    text specifying the `{"tool_calls": [...]}` output contract.
  - `[BEGIN OF QUERY]` ... `[END OF QUERY]` — the folded conversation history:
    - `user`/`assistant` plain-text turns pass through as-is.
    - Prior assistant `tool_calls` get echoed back as xLAM's own
      `{"tool_calls": [...]}` JSON text (so a second turn's folded-in history
      looks like something xLAM itself could have produced — same principle
      `tool-proxy`'s `normalize_messages` uses when it echoes its own router
      JSON back into context).
    - `tool`-role result messages get attributed to the call that produced them
      via a `call_names: dict[str, str]` map (`tool_call_id -> name`), built
      while walking prior assistant turns — this is the one piece of
      `tool-proxy`'s logic that transfers directly (see
      `tool-proxy/app/main.py:164-217`'s `normalize_messages` for the reference
      pattern, even though the output shape here is a prompt string, not a
      messages array).
- `call_llama_completion(base_url, prompt) -> str` — `POST {base_url}/completion`
  with `{"prompt": prompt, "temperature": 0, "n_predict": <bounded>}`. Same
  three-tier error handling as `tool-proxy`: connection/timeout ->
  `requests.exceptions.RequestException` -> 502; non-2xx -> 502 with upstream
  body as `detail`; unparseable JSON -> 502.
- `parse_xlam_response(raw_text) -> dict` — extract the `{"tool_calls": [...]}`
  (optionally wrapped with a `"thought"` field, both seen live this session)
  JSON object from the model's raw completion text, tolerating markdown code
  fences (some models wrap JSON in ` ```json ... ``` `). On any parse failure,
  fall back to `{"tool_calls": [], "content": raw_text}` — never crash on
  unexpected model output, same discipline as `tool-proxy`'s decision-parsing
  fallback at `main.py:367-373`.
- `to_openai_response(decision, raw_text) -> dict` — build OpenAI's
  `message.tool_calls` array (`id: f"call_{uuid4().hex[:12]}"`,
  `type: "function"`, `function.name`, `function.arguments: json.dumps(args)`,
  `content: None`, `finish_reason: "tool_calls"`) when `tool_calls` is non-empty;
  otherwise `{"role": "assistant", "content": ...}` with `finish_reason: "stop"`.
- `sse_chunk_response(...)` — single-chunk SSE (`chat.completion.chunk` +
  `[DONE]`) for streaming requests, same reasoning as `tool-proxy`'s own
  implementation: xLAM's output is a short JSON blob, not genuinely
  token-streamable.

Tests (`xlam-proxy/tests/test_main.py`, pytest + FastAPI `TestClient` +
`monkeypatch` on `requests`, same style as `tool-proxy/tests/test_main.py`):

- `build_xlam_prompt`: tool-schema flattening, single-turn query, multi-turn
  fold-in (prior tool_calls + tool results, `call_names` attribution).
- `parse_xlam_response`: valid JSON, JSON wrapped in markdown fences, malformed
  JSON (fallback path).
- `to_openai_response`: tool-call shape, plain-content shape.
- Upstream failure mapping: connection refused, timeout, non-200, unparseable
  body -> all 502 with a `detail` field.
- End-to-end `/v1/chat/completions` with `requests.post` monkeypatched to a
  `FakeResponse` (same pattern as `tool-proxy`'s `FakeResponse` class).

## 2. `scripts/runtime-adapters/xlam-proxy.ps1` (new runtime adapter)

Dot-sources `agent-state-helpers.ps1`, `adapter-contract-helpers.ps1`, and the
existing `llamacpp.ps1` (reused for the underlying llama-server process — not
duplicated).

- `Get-AirlockXlamProxyBaseUrl` — fixed Airlock-chosen port, default `12348`
  (next after `tool-proxy`'s `12347`) since, unlike bare llama-server, this
  proxy is fully Airlock-owned and can have a stable conventional port. Reads
  `state/xlam-proxy-instance.json` if present, else the default.
- `Resolve-XlamProxyEndpointMode -Harness <opencode|pi-worker|aider|openclaw>` ->
  `{TransportCandidates: ["openai-direct"]; Reason}` — single-candidate shape,
  same as `Resolve-LlamaCppEndpointMode`, since this proxy also exposes exactly
  one OpenAI-compatible route.
- `Start-XlamProxyRuntime` — orchestrates two processes in order:
  1. Calls the existing `Start-LlamaCppRuntime` (from `llamacpp.ps1`) to bring
     up `llama-server` on the xLAM GGUF with `--ctx-size 6144` and no explicit
     `-ngl` override (let llama.cpp's auto-fit choose GPU layers — an explicit
     `-ngl 99` was tried and OOM'd this session; auto-fit succeeded on the
     first retry).

     **Correction (implementation session, live-verified):** the original
     claim above — "do not request more [than 4096]... overflows training
     context and OOMs the KV cache" — conflated two separate variables. The
     OOM was reproduced only in combination with the `-ngl 99` override, not
     from `--ctx-size` alone. Live-measured KV-cache overhead at `--ctx-size
     4096` was ~485MB beyond the 13.8GB model (14310MB used total on a
     15.7GB-free 16GB card) — comfortably supports doubling to 8192 on VRAM
     grounds alone. The real reason to move off 4096 at all: the actual
     ADR-012 capability contract (real opencode, this user's real global
     config/plugins, real `bash`/`read`/`write` tool schemas — the gate is
     unchanged, nothing stripped) stages a 5564-token prompt, which does not
     fit in xLAM's native 4096 training context at all, independent of model
     quality (llama-server returns a hard `exceed_context_size_error`, not a
     model-quality failure). `6144` was chosen over `8192` to minimize RoPE
     extrapolation past the model's trained length while still clearing 5564
     tokens with ~580 tokens of margin — a conservative middle choice, not a
     hardware ceiling.
  2. Launches the Python proxy (`uvicorn app.main:app`) pointed at the
     llama-server base URL just returned, polls its own `/health`.
  3. Records `state/xlam-proxy-instance.json`: proxy PID, start-time ticks,
     instance nonce, proxy port, AND the underlying llama-server's port/PID
     (needed for correct teardown order in step below).
  4. Writes a JSONL audit entry, same shape as `Write-LlamaCppAuditLog` /
     `Write-ToolProxyAuditLog`.
- `Get-XlamProxyInspection` — checks the proxy's own `/health`, not llama-server's
  `/props` (no chat_template verification here — see "why no template check"
  below).
- `Stop-XlamProxyIfOwned` — stops the Python proxy first (via the same
  four-factor `Resolve-AirlockStopOwnership` gate every other adapter uses:
  recorded-owner-alive, PID match, start-time match, instance-nonce match), then
  delegates to `Stop-LlamaCppIfOwned` for the underlying llama-server. Order
  matters: stopping llama-server first would leave the proxy briefly serving
  502s to a dead upstream.

**Why no template-verification step**: `Resolve-LlamaCppTemplateVerification`'s
marker allowlist (`tool_call`, `tool_calls`, `[TOOL_CALLS]`, `<tools>`,
`function_call`) exists to fail closed when trusting llama-server's own
`--jinja` chat-template rendering. This adapter doesn't trust that rendering at
all — it hits `/completion` directly with a hardcoded, known-correct prompt
template, bypassing the chat_template entirely. The correctness guarantee here
comes from the proxy's own fixed code, verified by the ADR-012 capability
contract itself (real opencode -> proxy -> llama-server -> real tool_use
events), which is a stronger, more direct check than a template-marker
heuristic anyway.

## 3. `config/agent-profiles.json` — new profile

```json
{
  "profileId": "xlam-proxy-7b-fc-r",
  "displayName": "xLAM-7b-fc-r via llama.cpp translation proxy",
  "runtime": "xlam-proxy",
  "transportCandidates": ["openai-direct"],
  "modelRef": "hf.co/Salesforce/xLAM-7b-fc-r-gguf",
  "acquisition": { "kind": "huggingface-gguf", "requiresConfirmation": true },
  "initialContext": 6144,
  "minimumFreeVramGiB": 14,
  "runtimeArgs": [],
  "toolSurface": "lean",
  "candidateOnly": true
}
```

`initialContext: 6144` — see §2's correction above for why this is 6144, not
xLAM's native 4096 training context. `minimumFreeVramGiB: 14` leaves ~2GB
headroom above the 13.8GB model size for KV cache, matching the auto-fit
behavior already observed working. `runtimeArgs` left empty deliberately —
GPU-layer selection is handled by `Start-LlamaCppRuntime`'s auto-fit, not
surfaced as a profile-level override, unless a future finding shows auto-fit
insufficient.

## 4. `scripts/Start-AgentSession.ps1` wiring

- Dot-source `runtime-adapters/xlam-proxy.ps1` alongside the other adapters
  (`Start-AgentSession.ps1:27-29`).
- Add an `"xlam-proxy"` case to `Resolve-SessionEndpointMode`
  (`Start-AgentSession.ps1:38-46`) calling `Resolve-XlamProxyEndpointMode`.
- Add an `"xlam-proxy"` arm to the runtime switch (`Start-AgentSession.ps1:
  128-183`) calling `Start-XlamProxyRuntime` / `Get-XlamProxyInspection`,
  setting `$runtimeVersion`/`$modelDigest`/`$chatTemplateIdentity` — for
  `$chatTemplateIdentity`, use the honest `"unknown"` sentinel (the
  llama-server/LM Studio precedent for "this runtime doesn't have a comparable
  concept") since the proxy's correctness doesn't come from a verified
  template identity.

## 5. Acceptance gate (unchanged from ADR-012)

`Invoke-AirlockOpenCodeCapabilityContract -ModelRef hf.co/Salesforce/xLAM-7b-fc-r-gguf
-EndpointUrl http://127.0.0.1:12348/v1` — 3/3 trials must pass, using real
`bash`/`read`/`write` tool calls through opencode's actual system prompt (not
just the toy single `get_weather` call already proven manually this session).
This is the real, non-negotiable bar — a passing curl test against a toy tool is
necessary evidence but not sufficient to declare this ADR done.

## 6. CI

Add an `xlam-proxy-tests` job to `.github/workflows/ci.yml`, same shape as the
existing `tool-proxy-tests` job (Ubuntu runner, Python 3.11, `pip install -r
requirements.txt pytest httpx`, `pytest tests/ -v`).

## Open questions to resolve during implementation (not blocking, but flagged)

- Benchmark llama.cpp's Vulkan backend tokens/second for xLAM against Ollama's
  CUDA path before declaring this production-ready for interactive use — not
  measured yet (flagged in ADR-013's trade-offs too).
- Whether `n_predict` needs a real bound (a hung/rambling completion could block
  a request indefinitely) — `tool-proxy` doesn't face this because Ollama's
  `format` grammar constrains output length implicitly; `/completion` has no
  such constraint, so this proxy needs its own timeout/max-token discipline.
- `config/opencode.json.template` real-usage wiring (a documented example
  provider entry pointing at port 12348) is a documentation task, not part of
  the ADR-012 harness path, which builds its own config from scratch per
  `Get-OpenCodeStagedConfigContent`.
