# ADR-013: llama.cpp + xLAM translation adapter for agentic tool-calling

## Status
Proposed. Supersedes pure-Ollama model selection for the agentic tool-calling role established
in ADR-012 / ADR-005. ADR-012's capability contract stays as the acceptance gate; this ADR
changes what runtime and model combination can pass it.

## Context

ADR-012 built a live capability contract (write a marker, invoke opencode against a real
Ollama endpoint, verify a structured tool-call event) as the gate for declaring a model
"ready" for agentic coding. Running that contract live against every promising local
tool-calling candidate on this hardware (RTX 5000 Ada, 16GB VRAM) produced a decisive,
evidence-backed result:

**0 of 9 tested Ollama-native models pass**, split into two distinct, independently
verified failure modes:

1. **VRAM spillover** (models 13GB+: Qwen3.8-27B, qwen3.6:27b, qwen3.6:35b-a3b,
   Muse Glimmer 30B) — the model doesn't fit in 16GB VRAM and Ollama's CPU/RAM
   spillover causes 120s+ timeouts or complete hangs, independent of tool-calling
   quality. Confirmed live; not fixable in software on this hardware via Ollama.
2. **Genuine model decision-quality failure** (models that fit: ornith:9b,
   devstral-small-2:24b, qwen2.5-coder:7b, qwen3-coder:30b) — verified at the wire
   level with a logging proxy inserted between opencode and Ollama. opencode
   correctly declares all tools with valid JSON schemas (`tools: 10`,
   `tool_choice: "auto"`); Ollama's response never contains a `tool_calls` event
   across dozens of captured turns. The model narrates its intent in plain text
   instead of emitting a structured tool call. This is not a config bug, not a
   harness detection bug, not a context-window truncation issue (reasoning traces
   were consistently under 2K characters, nowhere near default context limits) —
   it is the model's own trained behavior under a real multi-tool agentic system
   prompt, as opposed to a toy single-tool curl test where the same models can look
   fine in isolation.

A further attempt to unlock `xLAM-7b-fc-r-gguf` (Salesforce, ranked #3 on the Berkeley
Function-Calling Leaderboard, 88.24%) directly through Ollama's `hf.co/...` GGUF import
failed immediately: Ollama returned `"does not support tools"`. Inspecting the imported
model's manifest showed why — Ollama's importer generated a bare Alpaca-style template
(`{{.System}}\n### Instruction:\n{{.Prompt}}\n### Response:`) with no tool-calling grammar
at all, discarding a real `tokenizer.chat_template` key that is present in the GGUF's own
metadata. **This is an Ollama import-path limitation, not evidence against the model.**

Installing llama.cpp directly (winget `ggml.llamacpp`, pointed at the same GGUF weights
already sitting in Ollama's blob store — no re-download needed) and driving the model with
its own `--jinja` template resolution still did not produce a tool call through the OpenAI
`tools` API shape opencode sends: the embedded template isn't written to consume that
parameter. But prompting the model directly in the format Salesforce documents on the
model card (`[BEGIN OF TASK INSTRUCTION]` / `[BEGIN OF AVAILABLE TOOLS]` /
`[BEGIN OF FORMAT INSTRUCTION]` / `[BEGIN OF QUERY]` blocks, a flattened parameter schema,
and a `{"tool_calls":[...]}` output contract) produced a correct, well-formed tool call on
the first try at temperature 0. This is the only model, out of every candidate tested this
session, to demonstrate a genuine, correct tool-call decision through this hardware's
actual constraints.

Three externally-suggested candidates (DeepSeek-V4-Flash, GLM-5.3-Flash "uncensored",
OrcaRouter) were fact-checked via web research before any download attempt and ruled out
on hard numbers, not runtime choice:

- DeepSeek-V4-Flash: real, MIT-licensed, 284B total/13B active MoE. Smallest available
  GGUF quant is 1-bit at 82.5GB — does not fit this hardware on any runtime.
- GLM-5.3-Flash "uncensored": real base model (320B/18B active), but the "uncensored"
  builds are unofficial third-party re-quants from small accounts. Smallest is ~121GB —
  same verdict.
- OrcaRouter: not a local model at all. It is a paid cloud API routing gateway; its
  Hugging Face org account re-uploads other people's quants, which is why it appeared
  in model search results.

A fourth candidate, `qwen3.6:35b-a3b` (23GB MoE, already pulled), was retried through
llama.cpp with `--cpu-moe` to test whether CPU-offloaded experts would avoid the VRAM
spillover seen under Ollama. It failed to load at all: the GGUF's `qwen35moe.rope
.dimension_sections` metadata has 3 entries where mainline llama.cpp (confirmed on the
latest available build via `winget upgrade`) expects 4 — this specific community quant
was built against an unmerged experimental fork, not something fixable by configuration.

## Decision

Adopt a translation-adapter pattern for the tool-calling role, rather than continuing to
search for an Ollama-native model that passes ADR-012's contract as-is:

1. **Runtime**: `llama-server` (llama.cpp), fronting the same GGUF weights already on
   disk. Ollama remains available for non-agentic chat and any future model whose chat
   template genuinely supports OpenAI-shaped tool calls natively.
2. **Model**: `xLAM-7b-fc-r-gguf` (13.8GB, fits the 16GB card with headroom) as the
   tool-calling model for agentic coding sessions.
3. **New component**: a small translation proxy — same pattern as this repo's existing
   `tool-proxy/app/main.py`, retargeted at llama.cpp instead of Ollama — that:
   - Accepts opencode's real `/v1/chat/completions` request (OpenAI-shaped `messages`
     + `tools` array).
   - Re-renders it into xLAM's native prompt format (task/tools/format/query blocks,
     flattened parameter schema).
   - Calls llama-server's `/completion` endpoint.
   - Parses the model's `{"tool_calls":[...]}` JSON response and translates it back into
     OpenAI's `message.tool_calls` shape (id, `type: "function"`, `function.name`/
     `function.arguments` as a JSON string) so opencode's existing client code needs no
     changes.
   - Handles multi-turn continuation: prior tool calls and their results must be folded
     back into the `[BEGIN OF QUERY]` block (or an equivalent multi-turn convention) so
     a real read-file-then-write-file agentic loop is representable, not just a single
     isolated tool call.
4. **Acceptance gate unchanged**: the new proxy + model combination must pass ADR-012's
   existing capability contract (3-trial workspace test through the real
   opencode-invocation path) before it can be declared ready, exactly like any other
   candidate. No new "simplified" gate is introduced for this ADR.

## Consequences

- Airlock gains its first agentic tool-calling model verified to genuinely decide to call
  tools, not just structurally support the API shape.
- The proxy adds real, testable code and a new failure surface (translation correctness,
  multi-turn state folding) — this must be covered by the same trial-based evidence
  discipline as the rest of ADR-012's work, not accepted on a single successful curl call.
- Ollama is not being replaced platform-wide; this ADR scopes llama.cpp adoption strictly
  to the tool-calling role, for this one model, until further evidence justifies widening
  it (see ADR-020 in prior brainstorming for a fuller runtime-pluggability discussion,
  which remains unimplemented and out of scope here).
- qwen3.6:35b-a3b, DeepSeek-V4-Flash, GLM-5.3-Flash "uncensored", and OrcaRouter are
  recorded here as evaluated and rejected so they are not re-investigated without new
  evidence (e.g., mainline llama.cpp merging the fork qwen3.6 needs, or a hardware upgrade
  large enough for 82GB+ models).

## Trade-offs

- The translation adapter is bespoke to xLAM's specific prompt contract; it does not
  generalize to other function-calling-specialist models without further adapter work per
  model family.
- llama.cpp's Vulkan backend (this machine's installed build) has not been benchmarked
  against Ollama's CUDA path for raw tokens/second; if xLAM proves too slow in practice,
  that is a separate, measurable finding to capture before declaring this ADR's approach
  production-ready.
- The adapter is unproven end-to-end (multi-turn, real coding tools like `bash`/`read`/
  `write`, not just a single weather-tool toy call) until it passes ADR-012's contract.
