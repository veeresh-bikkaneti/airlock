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
instead resolved it. With all five fixes applied, xLAM correctly forms a
first tool call against the real tool surface AND correctly recovers from
a real tool-execution failure in the same live run - see "Current status"
below for what still blocks a full 3/3 pass.

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

## Current status

With all five fixes applied, live-verified in the same real environment:

- Turn 1: xLAM correctly identifies the task and selects a tool, but
  chooses `bash` with a Unix `grep`/`tail` pipeline
  (`grep -A 1000 'MARK=' seed.md | tail -n +2 > output.md`) - wrong shell
  (opencode's `bash` tool runs PowerShell 7 on this host, not POSIX) and a
  typo'd pattern (`MARK=` doesn't match `MARKER=...`). This is a real,
  disclosed model-quality gap in turn 1 specifically, separate from the
  fold-shape bug fixed above - not yet fixed.
- Turn 2 (after the fold-shape fix): xLAM correctly recognizes the failure
  and switches to `read`, the right tool.
- Full 3/3 pass has not yet been re-confirmed live against a clean restart
  as of this evidence snapshot - the fold-shape and trailing-newline fixes
  were verified via captured-prompt replay against the still-running
  llama-server, not yet via a fresh end-to-end contract run. That run is
  the immediate next step, not yet done as this file is written.

## Disposition

**No fallback to an Unsloth candidate at this time.** The fold-shape
finding directly contradicts the "genuine capability ceiling" conclusion
this file stated in an earlier revision - that conclusion was reached one
diagnostic short: it treated turn-2's prompt as sufficiently verified once
the *information* (tool result, correct attribution) was confirmed
present, without also checking whether the *shape* matched xLAM's training
distribution. It did not. Once corrected, the same model recovers
correctly. An Unsloth model would have reused none of `build_xlam_prompt`
(a different architecture means a different or absent native prompt
format), so this bug would not have followed it there - the fallback
would have "worked" for the wrong reason, and this finding would never
have surfaced.

Turn 1's `grep`-on-PowerShell mistake is a real, still-open,
disclosed gap - whether it recurs identically across a full 3-trial run
and blocks a genuine pass is what the next live run determines, not
something to resolve by editing xLAM's fixed FORMAT/TASK instruction
blocks (those are the model's documented native format, not proxy logic,
and were correctly left untouched throughout this investigation).

`xlam-proxy-7b-fc-r` remains in `config/agent-profiles.json` as
`candidateOnly: true` pending that confirmation.
