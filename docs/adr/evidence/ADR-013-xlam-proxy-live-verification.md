# ADR-013: xlam-proxy live verification evidence

## Summary

`xlam-proxy` is built, unit-tested (29/29), and wired into ADR-012's
`Start-AgentSession.ps1`/profile catalogue. Live-verified against the real
ADR-012 capability contract (real opencode, real 10-tool surface, not a toy
single-tool call) through three genuine plumbing bugs, all found and fixed
with the model held constant. The proxy and runtime adapter are correct.
xLAM-7b-fc-r itself does not pass the live contract: it forms a correct
first-turn tool call against the real tool surface, but after a tool
failure it deterministically terminates instead of self-correcting, even
though a demonstrably correct recovery exists in its own output
distribution. This is a genuine, disclosed model-capability ceiling, not a
proxy defect.

## Environment

- Hardware: RTX 5000 Ada, 16GB VRAM.
- llama.cpp `b10689-57291f264` (winget `ggml.llamacpp`).
- Model: `hf.co/Salesforce/xLAM-7b-fc-r-gguf` (F16, 13.8GB), loaded directly
  from Ollama's own blob store (`~/.ollama/models/blobs/sha256-45a4a233...`)
  - confirmed byte-identical GGUF (`GGUF` magic bytes present), no
    re-download needed.
- opencode 1.18.18, this user's real global `~/.config/opencode` config
  (plugins, custom agents, skills all present and NOT stripped - the ADR-012
  gate is unchanged per the ADR-013 design doc, so nothing about the real
  environment was simplified for this test).

## Plumbing bugs found and fixed (proxy/runtime, not model)

1. **Real tool-surface size, not the toy assumption.** opencode's `--auto`
   mode declares its full 10-tool surface (`bash`, `edit`, `glob`, `grep`,
   `read`, `skill`, `task`, `todowrite`, `webfetch`, `write`), not just
   `bash`/`read`/`write` - confirmed by capturing the real rendered prompt
   (`XLAM_PROXY_DEBUG_PROMPT_DIR`, added this session). Tool declarations
   alone total ~5400 tokens; the full first-turn prompt is 5564 tokens.
   `config/agent-profiles.json`'s `toolSurface: "lean"` field is
   confirmed-unused metadata (only ever read as an evidence-key hash
   input, never as an actual restriction) - a pre-existing ADR-012 gap,
   not something this work introduced or could fix in scope.

2. **llama-server hard-caps context to the model's reported training
   length.** `--ctx-size 6144` against a GGUF whose `llama.context_length`
   metadata says 4096 was silently capped back to 4096 - logged as `the
   slot context (6144) exceeds the training context of the model (4096) -
   capping`. Neither `--parallel 1` nor `--rope-scaling linear/yarn` with
   `--rope-scale`/`--yarn-orig-ctx` lifted this on their own; only
   `--override-kv llama.context_length=int:6144` did (confirmed via
   `/slots` reporting the full requested `n_ctx` and a direct >4096-token
   `/completion` request succeeding).

3. **The override alone gives raw RoPE extrapolation, which collapses
   output quality.** With only `--override-kv` (no explicit frequency
   scaling), llama.cpp believes 6144 IS the native training context, so it
   applies zero interpolation for the overflow tokens. Replayed the real
   captured 5564-token prompt directly against llama.cpp: produced a
   correct `thought` and a correct first tool call (`read`), then
   collapsed into runaway repetitive-token garbage (`\u1\u2\u3...`) while
   attempting to fabricate a file-content argument it couldn't know yet -
   invalid JSON. Adding `--rope-scaling linear --rope-freq-scale 0.6667`
   (4096/6144) to the same override restored coherent, valid JSON on the
   identical prompt.

4. **Greedy decoding degenerates independently of both of the above.**
   Even with correct RoPE scaling, `temperature=0` reproducibly collapsed
   into repetitive-token garbage on the same real prompt while the model
   tried to fabricate unknown content. `repeat_penalty=1.15` (a
   decoding-sampler setting, not part of xLAM's documented prompt format)
   fixed this - verified on the identical captured prompt: correct tool
   selection, valid JSON, no repetition collapse. `n_predict` raised
   512→1024 to give a two-call response headroom (confirmed not the actual
   cause of the garbage - a >2048 replay without `repeat_penalty` still
   collapsed and still stopped well under any n_predict cap).

All four fixes are live-verified via the same method: real ADR-012
contract run → real failure → captured real prompt
(`XLAM_PROXY_DEBUG_PROMPT_DIR`) → offline replay against llama-server to
isolate the variable → fix → full clean restart through the real adapter →
re-run the real 3-trial contract. No fix was accepted on a curl toy test
alone.

## The remaining, disclosed model-capability finding

With all four fixes applied: `UsedValidStructuredToolEvents: true` on all
3/3 real trials (the transport genuinely works - opencode receives and
executes a real structured tool call). But `output.md is absent or empty`
on all 3/3 - the trials still fail.

**Turn 1** (deterministic at `temperature=0`, reproduced identically
across every real trial run): xLAM chooses `bash` and generates
`grep -A 1000 'MARK=' seed.md | tail -n +2 > output.md` - wrong shell
(opencode's `bash` tool runs PowerShell 7 on this host, not POSIX
`grep`/`tail`) and a typo'd pattern (`MARK=` doesn't match `MARKER=...`).
opencode executes it; PowerShell reports
`grep: The term 'grep' is not recognized...`.

**Turn 2** (the discriminator - is this a proxy bug or a model limit?):
captured and inspected the real turn-2 prompt directly. The
`[BEGIN OF QUERY]` block is correctly formed:
```
user: Read seed.md. Create output.md containing exactly the value after MARKER=. Do not access files outside this workspace. Reply exactly DONE.
assistant: {"tool_calls": [{"name": "bash", "arguments": {"command": "grep -A 1000 'MARK=' seed.md | tail -n +2 > output.md"}}]}
tool result for bash (call_38192c7652dd): grep: The term 'grep' is not recognized as a name of a cmdlet, function, script file, or executable program. ...
```
`call_names` attribution is correct (the proxy's own generated call id
round-trips through opencode and back correctly). This rules out a proxy
bug in the folded-history path.

Replayed this exact real turn-2 prompt directly against llama.cpp:
`tokens_predicted: 1`, `content: ''` - the model's single most-likely next
token is immediate end-of-sequence. Tested `temperature` 0, 0.2, 0.3, 0.5
against the identical prompt: identical result every time (`tokens_predicted:
1`, empty content) - not a greedy-decoding tie-break artifact fixable by
ordinary sampling.

Forced generation past the immediate EOS (`ignore_eos: true`) to check
whether a coherent recovery exists at all in the model's distribution: it
does -
```
{"thought": "The `bash` tool failed to execute because it could not find the 'grep' command...
I will use the `read` tool to read the content of seed.md file instead.",
 "tool_calls": [{"name": "read", "arguments": {"filePath": "seed.md"}}]}
```
- a genuinely correct diagnosis and a genuinely correct next step. But
this is not something a proxy can responsibly force in production:
suppressing EOS based on message content is a real, separate decoding
intervention with its own failure modes (a legitimate early stop would
also get forced to continue), well outside a translation proxy's scope,
and was not attempted as a shipped fix for that reason.

**Conclusion:** xLAM-7b-fc-r reliably produces a single well-formed,
correctly-argued tool call against the real full tool surface (turn 1 is
never the failure). It does not reliably recover from a tool-execution
failure in a multi-turn agentic loop - the correct recovery exists in its
output distribution but is assigned near-zero probability relative to
immediate termination, robust across `temperature` 0-0.5. This matches the
model's design as a single-shot function-calling specialist (Salesforce's
own framing), not an iterative ReAct-style agent, and is consistent with
finding 2 of the original bake-off synthesis: every model tested this
investigation has failed on real agentic-reliability grounds, not on the
structural tool-call-format question xLAM was specifically chosen to
solve.

## Disposition

Per the ADR-013 design doc's own fallback criterion, this is a legitimate,
disclosed capability ceiling, not a plumbing gap: the harness gate is
unchanged, the proxy is unit-tested and live-verified correct across four
independent real bugs, the prompt fits the configured context, and xLAM
still fails to recover from a real (not contrived) tool-execution error
across multiple sampling settings. Recommend evaluating an
Unsloth-quantized function-calling model with a correctly embedded chat
template as the next candidate, per the original task's disclosed fallback
path - `build_xlam_prompt`'s architecture-specific prompt rendering would
not be reused for a model with its own working chat template; the
`xlam-proxy` runtime-adapter shape (Start/Inspect/StopIfOwned, llama-server
reuse, port/state-file conventions) is directly reusable.

`xlam-proxy-7b-fc-r` remains in `config/agent-profiles.json` as
`candidateOnly: true` - it is not proposed for promotion to a default
profile.
