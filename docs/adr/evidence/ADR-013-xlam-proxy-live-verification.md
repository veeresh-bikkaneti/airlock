# ADR-013: xlam-proxy live verification evidence

## Summary

`xlam-proxy` is built, unit-tested (30/30), and wired into ADR-012's
`Start-AgentSession.ps1`/profile catalogue. Live-verified against the real
ADR-012 capability contract (real opencode, real 10-tool surface, not a toy
single-tool call) through five genuine plumbing bugs, all found and fixed
with the model held constant. The fifth was the deepest: the proxy's
multi-turn history-folding shape (a "user:"/"assistant:" labeled dialogue
transcript, mirroring `tool-proxy`'s own `normalize_messages`) was
out-of-distribution for xLAM, which has no native multi-turn dialogue-role
concept at all. Folding history as one person's continuous narration
instead resolved it. With all five fixes applied, a full clean 3-trial
live run shows the proxy/transport/recovery layer working correctly on
3/3 trials, but the contract still fails 3/3 on a genuine model-capability
ceiling, not a plumbing bug - see "Current status" and "Disposition"
below for the byte-level evidence and the precise, narrow finding.

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

## Method

Every fix below was found and verified the same way: real ADR-012 contract
run → real failure → the exact real prompt captured via an opt-in debug
hook (`XLAM_PROXY_DEBUG_PROMPT_DIR`, added this session, off by default) →
offline replay against the still-running llama-server to isolate one
variable at a time → fix → full clean restart through the real
`Start-XlamProxyRuntime` adapter → re-run the real 3-trial contract. No fix
was accepted on a curl toy test alone; every fix was confirmed against a
real captured prompt from the real environment before being folded into
the code.

## Plumbing bugs found and fixed (proxy/runtime, not model)

1. **Real tool-surface size, not the toy assumption.** opencode's `--auto`
   mode declares its full 10-tool surface (`bash`, `edit`, `glob`, `grep`,
   `read`, `skill`, `task`, `todowrite`, `webfetch`, `write`), not just
   `bash`/`read`/`write`. Tool declarations alone total ~5400 tokens; the
   full first-turn prompt is 5564 tokens. `config/agent-profiles.json`'s
   `toolSurface: "lean"` field is confirmed-unused metadata (only ever
   read as an evidence-key hash input, never as an actual restriction) - a
   pre-existing ADR-012 gap, not something this work introduced or could
   fix in scope.

2. **llama-server hard-caps context to the model's reported training
   length.** `--ctx-size 6144` against a GGUF whose `llama.context_length`
   metadata says 4096 was silently capped back to 4096 - logged as `the
   slot context (6144) exceeds the training context of the model (4096) -
   capping`. Neither `--parallel 1` nor `--rope-scaling linear/yarn` with
   `--rope-scale`/`--yarn-orig-ctx` lifted this on their own; only
   `--override-kv llama.context_length=int:6144` did.

3. **The override alone gives raw RoPE extrapolation, which collapses
   output quality.** With only `--override-kv`, llama.cpp believes 6144 IS
   the native training context, so it applies zero interpolation for the
   overflow tokens. On the real captured 5564-token prompt this produced a
   correct `thought` and a correct first tool call, then collapsed into
   runaway repetitive-token garbage while fabricating an unknown
   file-content argument - invalid JSON. Adding `--rope-scaling linear
   --rope-freq-scale 0.6667` (4096/6144) to the same override restored
   coherent, valid JSON on the identical prompt.

4. **Greedy decoding degenerates independently of both of the above.**
   Even with correct RoPE scaling, `temperature=0` reproducibly collapsed
   into repetitive-token garbage on the same real prompt while fabricating
   unknown content. `repeat_penalty=1.15` (a decoding-sampler setting, not
   part of xLAM's documented prompt format) fixed this - confirmed on the
   identical prompt: correct tool selection, valid JSON, no repetition
   collapse. `n_predict` raised 512→1024 for headroom (confirmed not the
   actual cause of the garbage independently).

5. **The multi-turn fold shape was out-of-distribution for xLAM.** With
   fixes 1-4 applied, `UsedValidStructuredToolEvents: true` on 3/3 real
   trials (the transport genuinely works), but `output.md is absent or
   empty` on 3/3 - xLAM's real first tool call was a `bash` command that
   fails on this host (turn 1's own separate, still-open issue - see
   below), and turn 2 (after the failure was fed back) produced *zero*
   content. Captured and inspected the real turn-2 prompt directly: the
   fold logic itself was correct (tool result properly attributed to the
   right `call_id`, matching this file's own unit tests) - ruling out an
   attribution bug. Replayed the exact real turn-2 prompt against
   llama.cpp directly: `tokens_predicted: 1`, `content: ''` - immediate
   EOS. Tested `temperature` 0, 0.2, 0.3, 0.5 against the identical
   prompt: identical result every time - not a greedy-decoding tie-break
   fixable by ordinary sampling. Forced generation past the immediate EOS
   (`ignore_eos: true`) to check whether a coherent recovery existed at
   all in the model's distribution: it did -
   ```
   {"thought": "The `bash` tool failed to execute because it could not find the 'grep' command...
   I will use the `read` tool to read the content of seed.md file instead.", ...}
   ```
   - a genuinely correct diagnosis and next step, assigned near-zero
   probability relative to immediate termination. This pointed at the
   *shape* of the folded history, not the model's capability: the
   original fold rendered history as `user: ...` / `assistant: {...}` /
   `tool result for X (id): ...` labeled lines - a chat-style multi-turn
   transcript, the same convention `tool-proxy`'s own `normalize_messages`
   uses for Ollama. But xLAM's own `/props` `chat_template_caps` reports
   `supports_tools: false`, `supports_tool_calls: false` - it has no
   native multi-turn dialogue-role concept at all, only a single-query
   function-calling format. A role-labeled transcript reads to it as an
   already-concluded conversation.

   **Fix:** fold history as one continuous first-person narration instead
   of labeled turns - `I called <tool> with <args>. It returned:
   <result>.`, closing with a generic `Continue completing the original
   task.` when any tool activity occurred. Replayed the identical real
   prompt with only the fold shape changed (tools, instructions, and
   information content held constant): the model immediately produced the
   correct recovery (`read` tool, correct file) in 63 tokens, valid JSON,
   natural stop. Verified this survives temperature=0 (deterministic,
   matching the contract's own requirement) and does not regress the
   already-working turn-1 case.

   **A second bug surfaced isolating this one:** a prompt ending exactly
   at `[END OF QUERY]` with no trailing newline reproducibly triggered the
   same immediate-EOS failure on the corrected narrative shape too;
   appending a single trailing `\n` (harmless, and confirmed not to affect
   the already-working turn-1 prompt) fixed it. `build_xlam_prompt` now
   always returns text ending in `[END OF QUERY]\n`.

## Current status: full 3/3 re-run, real contract, byte-level artifacts

With all five plumbing fixes applied, ran a full clean `Start-XlamProxyRuntime`
restart followed by a real `Invoke-AirlockOpenCodeCapabilityContract` 3-trial
run (real opencode, real 10-tool surface, real `New-AirlockWorkspaceMarker`
markers). To see exactly what the model wrote rather than infer it from the
pass/fail reason string, trial workspaces were preserved for this one run via
a temporary opt-in flag added to and then reverted from
`Invoke-WorkspaceContract.ps1` (`AIRLOCK_PRESERVE_TRIAL_WORKSPACES`, default
off, never left in the codebase - it changes shared harness behavior for
every model profile, not just this one).

Result: **3/3 failed.** `UsedValidStructuredToolEvents: true` on all three -
the transport, tool declaration, and tool-execution loop all still work.
Turn 1 in every trial repeated the same `bash` mistake documented below
(Unix `grep`/`tail` against opencode's PowerShell `bash` tool, with the
pattern typo'd as `MARK=` instead of `MARKER=`). All three trials correctly
recovered from that failure via the fold-shape fix and issued a `read`,
which succeeded. What happened after the `read` is the new, decisive
finding:

- **Trial 1** (marker `26f9288fa5b76e6d1158a5bac168a1e5`) wrote `output.md`
  containing exactly:
  ```
  MARK=26f9857a1e43b0c9d87a5b1c896a5b4
  (End of file - total 1 lines)
  ```
- **Trial 2** (marker `97584275b3e0ca1a6cf8b5e1397f2bc9`) never called
  `write` at all - stopped cleanly (`exitCode=0`, no timeout) right after
  the successful `read`. `output.md` never existed.
- **Trial 3** (marker `74f6f511f267c1ff447767af80519d87`) wrote `output.md`
  containing exactly:
  ```
  MARK=74f6f51f267c1ff47af8
  ```

Reading trials 1 and 3 byte-for-byte against their real seed markers rules
out "poor verbatim fidelity on long hex strings" as the mechanism - it's
narrower and more specific than that. Trial 1's write reproduces the
marker's first 4 hex characters correctly (`26f9`), then drifts into a
plausible-looking but fabricated continuation. Both writes also carry
`MARK=` - the same wrong key the model typed into its turn-1 `grep`
pattern, consistently, across separate trials and separate random markers.
Trial 1's write additionally contains `(End of file - total 1 lines)` -
text that exists nowhere in the source data and appears **only** inside
the `read` tool's own result framing (`<content>\n1: MARKER=...\n\n(End of
file - total 1 lines)\n</content>`). The model did not extract the marker
value; it reproduced an approximate, prefix-anchored span of the `read`
tool's raw output structure into the `write` call's `content` argument.

That is the real mechanism: **xLAM does not isolate the target value from
surrounding tool-result text when composing a follow-up tool call's
arguments.** It correctly identifies *that* a value needs to be echoed
(turn selection is right, tool choice is right on 2/3 trials that reach
`write`), but the value it emits is a corrupted paraphrase of the tool
result's shape, not an extraction of its content. The third trial shows a
second, independent failure mode: the model sometimes stops generating
after a successful `read`, with no tool call and no plain-text answer, before
ever attempting `write`.

Both failure modes are in xLAM's own generation, on the same fold-shaped
prompt that already demonstrably fixed the earlier immediate-EOS bug (turn
1's `bash`-failure recovery works in all three trials of this same run).
No prompt-side mitigation was attempted for either failure mode: a
"copy the value character-for-character" instruction in the FORMAT block
would be tuning xLAM's fixed native prompt to this specific contract's
marker-extraction task, in the same out-of-scope category already ruled
out for turn 1's shell-dialect mistake below.

## Disposition

**This is a genuine, live-verified capability ceiling - not a proxy bug,
and not another instance of the fold-shape mistake this file corrected
in an earlier revision.** That earlier correction stands: this file
previously concluded a dead end one diagnostic short, by checking only
that the right *information* reached the model, not whether the prompt's
*shape* matched its training distribution. This finding was checked the
same way that correction demanded: real contract, real markers, byte-level
artifacts, the exact mechanism named (span-reproduction with drift, not
"can't copy long strings"), and no available prompt-side fix that wouldn't
be gaming this specific test.

The precise, narrow claim for the ADR record: **xLAM-7b-fc-r can select
tools and recover from tool failures correctly, but cannot reliably
extract-and-echo a value from a prior tool result into a new tool call's
arguments** - the exact shape ADR-012's capability contract requires.
This does not mean xLAM cannot do tool calling; it demonstrably can. A
task shape that doesn't require verbatim extraction from tool output
might still suit it.

Turn 1's `grep`-on-PowerShell/`MARK=` typo remains a real, separately
disclosed gap, reproduced identically in all three trials of this run -
also left unfixed, for the same out-of-scope reason (xLAM's FORMAT/TASK
blocks are its documented native format, not proxy logic).

`xlam-proxy-7b-fc-r` remains in `config/agent-profiles.json` as
`candidateOnly: true`. Per the original task instruction, the recommended
next candidate is an Unsloth-quantized function-calling model with a
correctly embedded chat template - not attempted in this session. That
fresh model acquisition, adapter path, and its own live-contract
verification arc is next session's task, not a continuation of this one:
the proxy infrastructure and its five verified fixes stand on their own
regardless of which model sits behind it.
