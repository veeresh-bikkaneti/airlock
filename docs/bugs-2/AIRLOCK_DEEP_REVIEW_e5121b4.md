# Airlock deep review: local agentic coding path

**Revision reviewed:** `e5121b41e9dd04bb9f89d642eda65c043d4c7abc` on `main` (20 August 2026). This review covers the newly added tool-call proxy, its Windows lifecycle scripts, model and OpenCode configuration paths, and the conditions required to build an application with local agentic tooling.

## Executive assessment

The new **tool-proxy is a meaningful improvement**, and its unit suite is healthy. It fixes a real class of failure by converting grammar-constrained Ollama output into an OpenAI-style `tool_calls` response. The repository’s Python tests, JSON validation, compilation checks, and public CI all pass on the pushed revision. [1] [2]

However, the repository **still does not provide a reliable “start Airlock, then build an app” path**. The principal failure is no longer just model choice. It is **orchestration drift**: backend selection, proxy lifecycle, OpenCode configuration, active model state, and model capability validation are independent mechanisms that can disagree. A user can therefore have a healthy Ollama endpoint, a passing CI build, and a non-working local coding agent at the same time.

> **Bottom line:** Airlock currently proves that its proxy translates mocked single-tool responses. It does not yet prove that the installed Windows machine can launch OpenCode, select the intended model, call tools repeatedly, recover from tool errors, respect the workspace boundary, and finish a real file-edit task.

## Test results

| Check | Result | What it proves | Important boundary |
|---|---:|---|---|
| Tool-proxy unit suite | **31 passed** | Request translation, single-tool response shaping, basic error handling, and mocked streaming behavior work as coded. | Every upstream call is monkeypatched; no model or OpenCode process runs. The test file explicitly states this boundary. [3] |
| Memory-service suite | **11 passed** | Existing retrieval behavior did not regress. | It does not cover agentic coding. |
| Python compilation and JSON parsing | **Passed** | Python files compile; reviewed JSON files and the OpenCode template are syntactically valid. | It does not validate runtime configuration locations or model availability. |
| Dependency check | **Passed** | Installed Python packages satisfy declared requirements. | It says nothing about Windows virtual environments or updated deployment state. |
| GitHub Actions run 38 for `e5121b4` | **Succeeded** | Declared Windows PowerShell self-tests plus the Linux Python jobs passed in CI. [1] | The workflow does not start Ollama, OpenCode, Docker/vLLM, or a real model agent loop. [2] |

I also executed focused black-box probes not present in the repository suite. They reproduced three defects: non-object messages return HTTP 500, `null` message entries return HTTP 500, and malformed JSON request bodies return HTTP 500. The proxy also demonstrably retains only the first of two prior tool calls. The latter behavior is documented by a passing unit test, but it is still incompatible with robust multi-tool agent work. [4]

## Why local app-building still fails

A normal user journey has too many uncoordinated steps. `ai-start` chooses or adopts an Ollama backend. The OpenCode template points to port `12347`, where the proxy listens. Yet the proxy is explicitly opt-in and `Start-AI.ps1` never starts it. A user who runs only `ai-start` and then OpenCode can therefore point OpenCode at a port with no listener. The repository documentation tells the user to remember a separate `ai-tool-proxy-start` command, but the template itself cannot enforce that prerequisite. [5] [6]

The selected runtime model can also differ from the model OpenCode uses. The startup selector favors an already-installed fitting model and still treats `supportsFunctionCalling` as a binary capability. It does not consume the policy’s `preferredLocalModel`; meanwhile, the OpenCode template statically defaults to Devstral. A global or project OpenCode configuration can instead preserve an old Qwen 7B default. These three locations can describe three different models, with no command proving which model is actually receiving Build-mode requests. [7] [8] [9]

The proxy adds a fourth stateful component. It finds Ollama’s port from `.active-port.json`, while its own lifecycle state is held in `.tool-proxy-port.json`. Neither `ai-start` nor an OpenCode launch command performs a transaction across all of these components. This explains the user-visible outcome: commands and health checks can look green independently while the complete agent path is broken.

## Bug report

| ID | Severity | Reproduction / evidence | Impact | Required fix |
|---|---|---|---|---|
| **AGENT-001** | **P0 — primary user blocker** | Copy the OpenCode template, which targets `http://127.0.0.1:12347/v1`; run `ai-start` but not `ai-tool-proxy-start`; then run OpenCode. The proxy is opt-in and `Start-AI.ps1` has no proxy invocation. [5] [6] | The default template targets a service that a normal startup does not launch. Users see connection failures or fall back to a stale direct/global config. | Replace manual coordination with one `ai-agent-start`/`ai-opencode` transaction. It must start/verify the selected backend, choose direct versus proxy endpoint, verify the proxy when required, and launch OpenCode only after all preconditions pass. |
| **AGENT-002** | **P0 — wrong model can silently run** | `Select-BestCuratedModel` ranks installed models above larger downloads. `preferredLocalModel` is policy intent, but startup does not read it. The OpenCode template independently defaults to Devstral; OpenCode may separately load an old global or project model. [7] [8] [9] | A 7B compatibility model can be the model actually serving agent turns even when the user believes Qwen3-Coder 30B or Devstral is selected. This directly recreates the raw-JSON/tool-loop failures you reported. | Make one active agent state authoritative: provider, model, exact digest/tag, endpoint, proxy state, capability verdict, and OpenCode invocation. Pass `--model` explicitly from that state; never trust “last used model.” |
| **AGENT-003** | **P0 — no real agent acceptance test** | The proxy tests explicitly mock upstream calls and do not run a model or OpenCode. CI contains PowerShell, memory-service, and proxy unit tests but no Ollama/OpenCode job. [2] [3] | Passing CI cannot show that the primary feature—local agentic coding—works. Regression can ship unnoticed. | Add a Windows self-hosted acceptance suite: start a real local endpoint, invoke OpenCode with a pinned model and a temporary workspace, require read → write → test success, and preserve workspace-scoped permission denial for external paths. |
| **PROXY-001** | **P1 — malformed requests crash the proxy** | My probes sent `messages: ["not-an-object"]`, `messages: [null]`, and invalid JSON. Each returned HTTP 500. `chat_completions` calls `await request.json()` without a decode guard and later assumes every message has `.get`. [10] | One malformed local client request can produce an internal server error. It also violates the proxy’s documented “do not crash the caller” behavior. | Validate JSON decode, `messages` type, each message object, role, content shape, and `tools` shape at the boundary. Return deterministic HTTP 400/422 errors. Add the three reproduced tests as red-first regressions. |
| **PROXY-002** | **P1 — parallel tool calls are silently lost** | `normalize_messages` preserves only `tool_calls[0]`; the existing unit test confirms this as a known limitation. [4] | Modern coding agents can request several reads/searches in one turn. Dropping all but the first can lose observations, cause loops, or lead the model to act on incomplete state. | Implement a router schema and OpenAI response shape supporting an array of calls, preserve every call with `tool_call_id`, and attach every corresponding tool result on the next turn. Until then, explicitly disable parallel tools in the supported harness profile rather than silently discarding work. |
| **PROXY-003** | **P1 — forced restart can corrupt proxy state** | In `Start-ToolProxy.ps1`, `-Force` skips reuse but does not stop a healthy proxy already bound to the same port. A replacement process can fail to bind while the old proxy satisfies the health check; the state file is then overwritten with the new dead PID. [11] | `ai-tool-proxy-status` becomes misleading, subsequent stop/start behavior becomes unreliable, and agent configuration drift is difficult to diagnose. | On `-Force`, verify process identity and stop the existing proxy first; wait for port release; start replacement; validate that the **recorded PID** owns the listener before writing state. Add a lifecycle regression test. |
| **PROXY-004** | **P1 — stale PID can terminate an unrelated process** | `Stop-ToolProxy.ps1` reads a PID from a state file and calls `Stop-Process` without verifying executable path, command line, bound port, or an Airlock-owned marker. [12] | Windows can recycle PIDs. A stale state file can kill an unrelated user process. | Require PID + loopback port ownership + command-line/path match before termination. If identity cannot be established, remove only stale state and require explicit user action. |
| **PROXY-005** | **P1 — streaming compatibility is unproven** | The proxy creates one SSE event with a complete `tool_calls` object. Its test checks generic SSE framing and a function name, but not the tool-call delta/index structure or an actual OpenCode streaming parser. [13] | OpenCode may parse non-streaming calls but fail in the default streaming path, leaving users with intermittent or client-version-specific agent failures. | Add an OpenCode integration test with streaming enabled. If it fails, emit standards-compliant indexed tool-call deltas or explicitly configure the supported local provider for non-streaming requests. |
| **VLLM-001** | **P1 — vLLM is not an agentic alternative today** | `Start-VLLM.ps1` defaults to Qwen2.5-Coder 7B AWQ. The proxy deliberately bypasses vLLM and states that its tool calling is unverified; it does not launch vLLM with auto tool-choice configuration. [14] [10] | Selecting the optional vLLM backend can regress the same primary agentic capability without a clear warning. | Mark vLLM `local-limited` until it has a separate end-to-end tool contract. Either configure and test native vLLM tool parsing or fail closed for agentic harnesses. |
| **DEPLOY-001** | **P2 — proxy virtual environment can drift after update** | `setup.ps1` always copies proxy code and `requirements.txt`, but `Start-ToolProxy.ps1` installs dependencies only when `.venv` does not exist. [15] [11] | A future requirements change can deploy code that expects packages absent from the existing venv. | Store a requirements hash in proxy state. Re-run dependency synchronization when it changes; expose this in `ai-tool-proxy-status`. |
| **PERM-001** | **P2 — path denial is misdiagnosed as agent failure** | The reported CV test resolved a home-directory absolute path and OpenCode denied it outside the workspace. That is correct safety behavior. | Users may weaken permissions to make an unreliable test pass, expanding the agent’s filesystem access unnecessarily. | Make the acceptance test create `cv.md` in a temporary project root and request `Read .\\cv.md`. Classify external-path attempts as a model/path-resolution defect, not a proxy defect. |

## What the proxy fixes—and what it cannot fix

The grammar-constrained router is a sensible compatibility layer for models that leak pseudo-tool JSON. It guarantees that the model’s output has one of two shapes: `call_tool` or `respond`. The proxy then turns that into a host-readable response. This is valuable because it moves formatting enforcement from the model to the decoder. [10]

It cannot, by itself, make a model reason correctly about repository scope, select the right file, recover from an error, choose several tools, obey workspace boundaries, or decide when to stop. The implementation itself acknowledges that constrained decoding guarantees output shape, not whether a tool call is semantically appropriate. [10] Airlock must therefore validate **the complete agent loop**, not only the JSON formatting step.

## Recommended architecture: one command, one source of truth

The correct primary feature is not another configuration template. It is an agent bootstrap transaction, for example `ai-agent-start`, with an OpenCode wrapper `ai-opencode`.

| Step | `ai-agent-start` responsibility | Required failure behavior |
|---|---|---|
| 1. Select | Load policy, list installed models, and select only a model with a current capability verdict. | If no validated agent fits, stop and offer `local-limited` or explicit handoff. Do not silently select 7B. |
| 2. Start backend | Start or verify Ollama; record model, exact endpoint, context target, and version. | Fail if the active endpoint differs from recorded state. |
| 3. Prove capability | Run a short tool contract: structured call, result-return turn, and temporary workspace read/write action. | Mark the current model/version as blocked on failure. |
| 4. Decide transport | Use direct Ollama only if the direct contract passes; otherwise start the proxy automatically and run the same contract through it. | Stop if neither direct nor proxy path passes. |
| 5. Publish state | Write a single `state/active-agent.json`: backend, model, endpoint, proxy PID/port, capability verdict, timestamp, and evidence versions. | State is written only after all prior checks pass. |
| 6. Launch harness | `ai-opencode` reads that file and passes explicit endpoint/model configuration. | Refuse when state is missing, stale, or points to a dead proxy. |

This reduces five independent “green” signals into one user-relevant result: **“local agent ready”** or a precise reason why it is not ready.

## Immediate implementation order

| Priority | Change | Why it should be first | Definition of done |
|---|---|---|---|
| **P0.1** | Implement `ai-agent-start` and `ai-opencode`. | It fixes the highest-probability reason a user cannot build an app: proxy/model/endpoint drift. | One command starts the needed components, prints the exact model and endpoint, and refuses OpenCode launch when readiness fails. |
| **P0.2** | Add the real Windows OpenCode workspace acceptance test. | It converts the primary feature from a claim into a release gate. | A pinned local model reads, edits, and tests a file in a disposable workspace; tests run against direct and proxy paths. |
| **P0.3** | Add a capability registry keyed by model digest, Ollama version, OpenCode version, endpoint mode, and context size. | It prevents an installed but unvalidated model from becoming an agent default. | Model selection cannot pick `unvalidated` or `blocked` for agent mode. |
| **P1.1** | Fix `Start-ToolProxy -Force` and identity-safe stop. | Current lifecycle code can create stale state and kill unrelated processes. | Tests prove force restart replaces the right process and stale state cannot kill an unrelated PID. |
| **P1.2** | Implement multiple tool calls or disable parallel calls explicitly. | Silent loss of calls is worse than a clear incompatibility. | Two calls plus two results survive a full normalized second turn. |
| **P1.3** | Add request-boundary validation and streaming-client integration coverage. | This removes reproducible 500s and proves the path OpenCode actually uses. | Malformed requests return 4xx; OpenCode streaming tool call completes end-to-end. |
| **P1.4** | Fail-close the vLLM agent path. | Today it advertises a backend whose tool behavior is explicitly unverified. | Agent mode refuses vLLM until a provider-specific contract passes. |
| **P2** | Add venv requirements-hash synchronization and better status output. | It makes future updates less fragile. | Status reports app version, requirements hash, backend/proxy identity, and last contract result. |

## Clear feedback on the current design

The repository is **substantially better tested than before**, and the tool-proxy work addresses a legitimate failure mode. The code quality in the proxy’s unit error handling is also improving: upstream connection failures are translated to 502 responses, malformed tool definitions are handled, and there is explicit documentation of model limitations. [3]

The remaining weakness is that the project has accumulated components instead of a product path. The code now has a backend chooser, model auto-selection, OpenCode templates, an opt-in proxy, a memory service, a task router, several state files, and drift detection. None currently owns the full question: **“Can this exact machine safely start a local coding agent and finish a workspace task right now?”** That is why a user can do substantial infrastructure work yet still be unable to build an app.

Do not solve this by forcing every model through the proxy or by permanently blacklisting a model from a catalogue. Start with Qwen3-Coder 30B as the candidate the user reports working, but make it earn the agent role through the contract suite on the actual machine. If direct Ollama passes, use direct Ollama. If direct fails but proxy passes, use the proxy automatically. If both fail, Airlock should say so plainly and hand off—not launch a model that looks connected but cannot act.

## Review limitations

This sandbox has no Windows host, running Ollama, user OpenCode configuration, Docker daemon, or locally loaded model. I therefore could not independently execute a real Qwen/Devstral turn or inspect the user’s active port/PID state. The report separates static code-proven defects and sandbox-reproduced proxy failures from real-model assertions. The required Windows acceptance suite is the missing mechanism that will close this limitation permanently.

## References

[1]: https://github.com/veeresh-bikkaneti/airlock/actions "Airlock GitHub Actions workflow runs"
[2]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/.github/workflows/ci.yml "Airlock CI workflow"
[3]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/tool-proxy/tests/test_main.py "Tool-proxy unit tests"
[4]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/tool-proxy/tests/test_main.py#L496-L518 "Documented single-call-only limitation"
[5]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/config/opencode.json.template "OpenCode template targeting proxy port 12347"
[6]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/scripts/Start-ToolProxy.ps1 "Opt-in tool-proxy lifecycle"
[7]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/scripts/Get-ModelAcquisition.ps1#L381-L480 "Model-selection algorithm"
[8]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/config/models.json "Model registry"
[9]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/config/policies/provider-policy.json "Provider policy"
[10]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/tool-proxy/app/main.py "Tool-proxy implementation"
[11]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/scripts/Start-ToolProxy.ps1#L113-L167 "Tool-proxy forced-start behavior"
[12]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/scripts/Stop-ToolProxy.ps1#L39-L50 "Tool-proxy shutdown behavior"
[13]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/tool-proxy/app/main.py#L178-L197 "Tool-proxy streaming implementation"
[14]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/scripts/Start-VLLM.ps1#L149-L154 "vLLM model and startup configuration"
[15]: https://github.com/veeresh-bikkaneti/airlock/blob/e5121b41e9dd04bb9f89d642eda65c043d4c7abc/setup.ps1#L33-L52 "Tool-proxy deployment and template handling"
