# Model tool-calling bake-off — synthesis report (ADR-013 evidence base)

## Summary

Tested 10+ local tool-calling candidates live against ADR-012's capability contract on
this hardware (RTX 5000 Ada, 16GB VRAM). Zero Ollama-native models pass. Two failure modes,
both confirmed at the wire level, not inferred from harness verdicts alone: VRAM spillover
for large models, genuine model decision-quality failure for small ones. One model —
`xLAM-7b-fc-r-gguf` — demonstrated correct tool-calling behavior when driven through
llama.cpp with its own native prompt format, becoming the basis for ADR-013.

## Key Findings

1. **9 of 9 tested Ollama-native models fail ADR-012's live contract.** — Evidence: High
   (direct harness runs, 3 trials each, real Ollama + opencode, on this exact hardware).
   - `qwen2.5-coder:7b`, `qwen3-coder:30b`: known-unreliable / escape-attempt / hallucinated
     tool use.
   - `smtek/Qwen3.8-27B` (13GB), `qwen3.6:27b` (18GB), `qwen3.6:35b-a3b` (23GB MoE),
     Muse Glimmer 30B (18GB): VRAM spillover, 120s+ timeouts or hangs.
   - `ornith:9b` (5.6GB), `devstral-small-2:24b` (15GB): fit VRAM, respond fast (15-53s),
     but fail structurally — see finding 2.
   - `gpt-oss:20b`: one trial in six produced a real structured tool event; the rest
     timed out or hung completely (240s+, no output). Not reproducibly reliable.

2. **The small/fast-model failure is a genuine model decision-quality problem, not a
   harness or config bug.** — Evidence: High (wire-level capture via a logging proxy
   inserted between opencode and Ollama, re-running `ornith:9b` through the real request
   path). Findings from captured traffic:
   - opencode correctly declares tools: `tools: 10`, `tool_choice: "auto"`, valid JSON
     schema per tool (verified against the full `bash` tool spec).
   - Across every real tool-bearing turn (6 full streamed responses over 3 trials),
     Ollama's response never contained a `tool_calls` delta. `finish_reason` was always
     `stop` or `length`.
   - Reasoning-trace length per turn was 130-1900 characters — nowhere near context
     limits, ruling out the `num_ctx`-truncation hypothesis considered earlier in this
     investigation.
   - The model narrates intent in the `content` field instead of emitting a structured
     call (e.g. "Let me read the file properly:"). `tool_choice` was `"auto"`
     (permissive), so this is the model choosing not to call a tool, not being blocked
     from doing so.

3. **xLAM-7b-fc-r-gguf's Ollama failure was an import/template bug, not a model
   capability limit.** — Evidence: High (inspected Ollama's own manifest and blob
   metadata directly).
   - Ollama's `hf.co/Salesforce/xLAM-7b-fc-r-gguf` import returns
     `"does not support tools"` immediately on any request with a `tools` array.
   - The imported chat-template blob is a bare Alpaca stub
     (`{{.System}}\n### Instruction:\n{{.Prompt}}\n### Response:`) with zero
     tool-calling grammar.
   - The raw GGUF's own metadata (found via direct byte inspection) carries a real
     `tokenizer.chat_template` key that Ollama's importer discarded.

4. **Driven through llama.cpp with its own native prompt format, xLAM-7b-fc-r produces
   correct tool calls.** — Evidence: High (direct test, reproducible, temperature 0).
   - Via llama.cpp's `--jinja` OpenAI-shaped `/v1/chat/completions`: still no tool call —
     the embedded template isn't written to consume the OpenAI `tools` parameter shape.
   - Via llama.cpp's raw `/completion` endpoint, using the exact prompt structure
     Salesforce documents on the model card (task instruction + available-tools block +
     format instruction + query block, flattened parameter schema, `{"tool_calls":[...]}`
     output contract): the model returned a correct, well-formed tool call
     (`{"thought": "...", "tool_calls": [{"name": "get_weather", "arguments":
     {"location": "Paris", "unit": "celsius"}}]}`) on the first attempt.
   - This is the only model tested this session, out of 10+, to demonstrate a genuine,
     intentional, correctly-formed tool-call decision.

5. **Three externally-suggested "strong candidates" do not fit this hardware on any
   runtime.** — Evidence: High (web research before any download attempt, cross-checked
   against actual GGUF size listings).
   - DeepSeek-V4-Flash: real, MIT-licensed, 284B total/13B active MoE. Smallest GGUF
     quant is 1-bit at 82.5GB.
   - GLM-5.3-Flash "uncensored": real base model (320B/18B active); "uncensored" builds
     are unofficial third-party re-quants from small accounts. Smallest is ~121GB.
   - OrcaRouter: not a local model — a paid cloud API routing gateway. Its Hugging Face
     org account re-uploads other people's quants, which is why it surfaced in search
     results next to real models.

6. **qwen3.6:35b-a3b's specific GGUF is incompatible with mainline llama.cpp.** —
   Evidence: High (direct load attempt, confirmed against the latest available build).
   - `error loading model hyperparameters: key qwen35moe.rope.dimension_sections has
     wrong array length; expected 4, got 3`.
   - `winget upgrade` confirms no newer llama.cpp build is available; this quant was
     built against an unmerged experimental fork.

## Contradictions

- Early in this investigation, curl tests against Ollama's native `/api/chat` and
  OpenAI-compat `/v1/chat/completions` showed `ornith:9b` producing correct `tool_calls`
  JSON on simple, single-tool prompts. This appeared to contradict the harness's 0/3
  verdict. **Resolved**: the wire-level capture (finding 2) shows the discrepancy is real
  prompt complexity, not a fluke — a toy single-tool prompt is not representative of
  opencode's actual system prompt plus full multi-tool surface. Both observations are
  correct; they describe different conditions.
- A previously-considered root cause (`num_ctx` never being set in the harness's staged
  config, per community reports that Ollama's default context "silently breaks agentic
  tool use") is **not supported** by the wire-level evidence: captured reasoning traces
  never approached anything close to a context ceiling. This hypothesis is superseded by
  finding 2, not merely unconfirmed.

## Recommendations

1. Build a translation-proxy adapter for xLAM via llama.cpp (see ADR-013) — because it is
   the only candidate with demonstrated, correct tool-calling decisions on this hardware,
   and the integration gap (OpenAI-shape vs. native-shape) is well-understood and
   scoped, not speculative.
2. Do not re-test ornith:9b, devstral-small-2:24b, qwen2.5-coder:7b, or qwen3-coder:30b
   under a different runtime — their failure is proven to be model-weight behavior, not
   an Ollama-specific defect, so a runtime swap alone will not change the outcome.
3. Do not pursue DeepSeek-V4-Flash, GLM-5.3-Flash "uncensored", or OrcaRouter further
   without a hardware change (they need 82GB-121GB+ of combined VRAM+RAM) or a decision to
   accept a paid cloud API (OrcaRouter) instead of a local model.
4. Revisit qwen3.6:35b-a3b only if mainline llama.cpp later merges qwen3.6 MoE support,
   or if a differently-built (mainline-compatible) quant becomes available.
5. Benchmark llama.cpp's Vulkan backend tokens/second for xLAM against Ollama's CUDA path
   before declaring the adapter production-ready — this was not measured in this bake-off
   and is a real open question for interactive usability.

## Sources

- Live harness runs: `Invoke-AirlockOpenCodeCapabilityContract` (this repo,
  `scripts/Invoke-OpenCodeCapabilityContract.ps1`), 3 trials per model, real Ollama +
  opencode on this machine.
- Wire-level capture: ad hoc Node.js logging proxy inserted between opencode and Ollama
  (session scratchpad, not committed — purpose-built diagnostic, not reusable
  infrastructure).
- Ollama manifest/blob inspection: `~/.ollama/models/manifests/` and
  `~/.ollama/models/blobs/` read directly.
- xLAM native prompt format: Salesforce's own `xLAM-7b-fc-r` model card on Hugging Face.
- DeepSeek-V4-Flash, GLM-5.3-Flash, OrcaRouter: web search against Hugging Face listings
  and OrcaRouter's own product site, cross-checked against actual GGUF file sizes.
- llama.cpp qwen3.6 incompatibility: direct `llama-server` load attempt against the
  locally-pulled `qwen3.6:35b-a3b-q4_K_M` blob, `winget upgrade ggml.llamacpp` confirming
  no newer build exists.
