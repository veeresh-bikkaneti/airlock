# Airlock Architecture and Production-Readiness Audit

**Audit date:** 2026-09-14
**Repository:** `veeresh-bikkaneti/airlock`
**Audit scope:** architecture, design patterns, implementation alignment, dead-code risk, test coverage, portability, and evidence required for public claims about local coding, chatting, reasoning, memory, and cloud-optional operation.

## Executive conclusion

Airlock has a coherent **modular-monolith direction** and several sound engineering patterns. Its strongest architectural idea is the separation between a **chat door** and a **coding door**, with hardware inspection, model acquisition, live capability verification, certificate publication, and optional memory routing around those doors. The code also uses useful safety patterns: fail-closed policy decisions, pure decision functions, explicit ownership, bounded worker manifests, atomic certificate publication, and evidence-bound runtime state.

However, the repository is **not yet proven as a production system for all machines**, and it should not make that claim today. The implementation is explicitly Windows-first, Linux is documented as later work, macOS is not a supported target, and the only live coding certificate described in the evidence is bound to one ThinkPad with one GPU, one model quantization, one llama-server configuration, and one Pi harness. The repository’s own documents correctly acknowledge this limitation.

The current test suite proves many invariants, but it does not prove the complete product on arbitrary hardware. The audit also found that the CI-style self-test run is not green in the current Linux validation environment: the agent-job helper test reports a host-home assertion failure, and the doctor test invokes the Windows-only `Get-CimInstance` cmdlet. Python service coverage is approximately **69% for memory-service** and **91% for tool-proxy** by statement coverage in this audit run. Those figures are useful signals, not proof of correctness.

The correct public position is therefore:

> **Airlock is a Windows-first, evidence-gated local AI platform with a tested modular core and a hardware-specific live coding proof path. It is not yet a cross-platform, universally validated local-AI product.**

## What was actually reviewed

The review covered the portable operating contract, product vision, README, CI workflow, architecture index, pending ADR index, model and provider configuration, installer entrypoints, PowerShell orchestration and helper modules, runtime adapters, memory-service modules and tests, tool-proxy modules and tests, the VS Code extension manifest, the root Python demo, test inventory, generated-artifact state, and a CI-style test run under PowerShell 7 on Linux.

The repository currently contains approximately **12,499 lines** across PowerShell, Python, and TypeScript production sources, **29 PowerShell self-test scripts**, **6 Python test modules**, and a separate VS Code extension build. This is large enough that architecture and ownership boundaries matter; it is no longer a small script collection that can be validated by a few smoke tests.

## Architecture assessment

### The effective architecture

Airlock is best described as a **modular monolith with adapter and policy layers**, not as a single linear script and not as a distributed service platform. The main execution path is coordinated by PowerShell, while Python services provide memory and tool-proxy capabilities. Configuration and evidence are stored in JSON and filesystem state. A VS Code extension is a client-side control surface rather than the platform core.

| Layer | Current responsibility | Assessment |
|---|---|---|
| User-facing control plane | `ai-start`, `ai-agent-start`, `ai-stop`, `ai-health`, profile helpers, setup and uninstall scripts | Coherent operational front door, but broad and heavily coupled to PowerShell globals and filesystem layout. |
| Hardware and model selection | VRAM/RAM inspection, quant ladder, Hugging Face acquisition, profile selection | Strong direction; real hardware behavior remains incompletely validated outside the evidence machine. |
| Runtime adapters | Ollama, llama.cpp, LM Studio, vLLM-related scripts | Good adapter intent, but adapter maturity is uneven and several paths are contract-tested rather than live-tested. |
| Agent capability gates | Pi, OpenCode, repair-loop, OpenClaw, worker-job contracts | Strong evidence-oriented design; not all gates are live end-to-end gates. |
| Memory plane | FastAPI memory service, Chroma storage, embeddings, coding proxy route | Reasonably separated, but service coverage is incomplete and runtime dependency compatibility is not fully locked down. |
| Tool-proxy plane | FastAPI translation layer for constrained tool calls | High unit coverage relative to the rest of the repository; still not proof of reliable multi-turn agent behavior. |
| State and evidence | Active certificates, capability registry, job manifests, audit logs, `.ai-context` | One of the strongest aspects of the design. It correctly distinguishes a model flag from a live verdict. |
| Optional worker isolation | Docker worker image and job-manifest path | Good security posture in the pure argument builder, but the live image build and execution path require dedicated integration coverage. |
| Presentation/control client | VS Code extension | Compiles, but its behavior is not covered by an extension test suite. |

### Design patterns that are present and appropriate

The implementation follows several recognizable patterns.

1. **Ports-and-adapters / hexagonal direction.** Runtime adapters isolate provider-specific behavior from parts of the selection and contract logic. This is the right direction for Ollama, llama.cpp, LM Studio, and future runtimes.

2. **Policy decision objects.** Functions such as network, output, certificate, profile, and task-route resolvers return explicit decision records rather than only booleans. This improves auditability and supports fail-closed behavior.

3. **Pure core, imperative shell.** Many PowerShell helpers are intentionally pure and are tested without a live daemon. The orchestration scripts then perform process, filesystem, Docker, and network I/O. This is a sound testability pattern.

4. **Capability-based routing.** The operating contract routes by required capability and evidence rather than vendor name. This is aligned with the tool-agnostic goal.

5. **Evidence-bound state machine.** The coding path moves through selection, acquisition, runtime startup, live contract verification, and certificate publication. The certificate is not published after a static model flag; it is published only after a live pass.

6. **Single-writer or ownership discipline.** The two-door model, active backend state, stop ownership, and atomic certificate replacement reduce resource conflicts and stale-state ambiguity.

7. **Fail-closed security controls.** Network defaults, command allowlists, worker privileges, output actions, and certificate validity are generally denied when required evidence is absent.

These patterns are appropriate. The problem is not that the repository has no architecture. The problem is that the architecture is only partially unified and only partially proven at its real runtime boundaries.

## Monolithic coherence versus fragmentation

The system has a **monolithic operational narrative**, but not yet a sufficiently strict monolithic implementation boundary. The intended loop is clear:

> inspect machine → select fitting model → acquire model → start owned runtime → prove capability locally → expose the correct door → persist memory → stop cleanly and record evidence

That loop should be the single spine of the product. At present, several parallel concepts coexist:

- chat through Ollama or vLLM;
- coding through llama-server and Pi;
- optional Ollama tool-proxy translation;
- LM Studio adapter contracts;
- OpenCode, OpenClaw, Codex, aider, Claude, and other harness documentation;
- a Docker worker-manifest architecture;
- a root Python local tester;
- a VS Code extension;
- memory-service and tool-proxy processes;
- historical Superpowers plans and experimental artifacts.

This is not inherently wrong, but it creates a risk that users experience Airlock as a collection of partially overlapping routes instead of one platform with explicit capability states. The remedy is not to remove modularity. The remedy is to define one canonical lifecycle and make every adapter, harness, and optional service attach to that lifecycle through explicit interfaces.

### Recommended canonical lifecycle

```text
Request
  -> classify capability and privacy requirements
  -> inspect hardware and environment
  -> select a fitting profile
  -> acquire or verify the exact artifact
  -> start one owned runtime
  -> run a live contract for the requested capability
  -> publish capability certificate only on pass
  -> expose chat or coding endpoint
  -> route optional memory with visible degraded state
  -> stop owned resources and retain evidence
```

Every public command should identify which stage it controls. Any feature that cannot enter this lifecycle should be labelled **experimental**, **connectivity-only**, or **out of scope**, rather than appearing equivalent to the proven coding door.

## Alignment with the stated vision

The implementation aligns well with the most important safety and honesty goals:

- It does not treat another machine’s 3/3 as a certificate for the user’s machine.
- It distinguishes chat from coding.
- It records known-failed Ollama agentic candidates instead of repeatedly retrying them.
- It sizes the coding model using a hardware-aware quantization ladder and has a CPU/RAM fallback concept.
- It makes memory degradation visible rather than silently claiming persistent memory.
- It uses local-first defaults and keeps cloud fallback opt-in in policy.
- It uses an operating contract that is vendor agnostic and includes a discussion gate.

The following vision claims are not yet proven at product level:

| Vision claim | Current status |
|---|---|
| Works on any PC | **Not proven.** Windows-first; hardware matrix is incomplete; Linux is explicitly open; macOS is not a supported implementation. |
| Pulls a model that fits this machine | **Partially implemented.** Selection logic exists, but all runtime residency and performance boundaries are not live-validated across hardware classes. |
| Coding works locally | **Proven only for the documented ThinkPad configuration and the exact live evidence path.** Not universal. |
| Chat works locally | **Partially proven.** Connectivity and adapter tests exist, but broad provider/model compatibility is not established. |
| Reasoning and thinking work | **Not a single verifiable capability contract.** Model metadata and tags are not an evaluation suite. |
| Tool calling and repair loops work | **Proven for the documented llama.cpp + Pi path on one machine; known failures are recorded for some Ollama candidates.** Not universal. |
| Memory lets sessions resume | **Unit and service behavior is tested; multi-process, crash-recovery, upgrade, and long-running persistence are not fully proven.** |
| Cloud optional operation is safe | **Policy intent is strong; connector-specific leakage, provider authentication, and adversarial boundary tests remain incomplete.** |
| All machines and operating systems are supported | **False today.** Documentation itself says Windows first and Linux later. |

## Dead code and orphaned-code assessment

A repository-wide search did not justify claiming that all dead code has been removed. Several files are better classified as **orphan candidates, experimental paths, or manually invoked components** until they have explicit ownership and integration tests.

### Confirmed or high-confidence cleanup candidates

1. **Generated Python bytecode exists in the working tree inventory.** The `.gitignore` excludes it, so it may be untracked rather than committed. It should still be removed from developer workspaces before packaging and CI artifact collection.

2. **`package-lock.json` is modified only because the package version changed from `0.1.0` to `0.2.0`.** This is not dead code, but it is an unrelated working-tree change that should be intentionally committed or reverted rather than left mixed with platform repairs.

3. **The root `main.py` is a standalone local tester, not part of the canonical Airlock lifecycle.** It defaults to `devstral-small-2:24b`, which the repository’s own evidence marks as failing for agentic loops. That is acceptable for a chat smoke tester only if it is explicitly labelled as such; otherwise it is a misleading parallel entrypoint.

4. **`Build-AirlockWorkerImage.ps1` has no obvious active caller in the main operational path.** It appears to be a manual prerequisite for the worker path. That is not necessarily dead, but its status must be explicit: either integrate it into a validated worker setup command or label it as an operator-only build step with an end-to-end test.

5. **LM Studio, OpenClaw, OpenCode, vLLM, and worker-container routes have uneven evidence.** Many are contract-tested or adapter-tested without a real service. They should not be presented as equivalent production routes.

6. **Historical `docs/superpowers/` plans and generated demo content create search noise.** They are valuable project history, but they should not be mixed with normative architecture guidance. A clear `archive/` or `historical/` classification would reduce routing mistakes by both humans and agents.

### Contradictory or dangerous stale configuration

`config/policies/provider-policy.json` currently names `devstral-small-2:24b` as the preferred local model and lists `qwen3-coder:30b` and `qwen2.5-coder:7b` as local fallbacks. The model registry and operating contract explicitly document these models as unsuitable for reliable agentic coding loops. This is not necessarily a contradiction for **chat**, because the chat door is intentionally separate, but the configuration is easy for a caller or agent to misread as a coding fallback list.

The configuration should therefore encode the distinction directly, for example with separate `chatModelPolicy` and `codingCapabilityPolicy` sections. A model marked `agenticLoopVerdict: fail` must be structurally ineligible for the coding door, not merely discouraged in prose.

## Test and verification findings

### What passed or was demonstrated

The repository contains extensive pure-function PowerShell tests. Earlier focused validation passed the memory-service suite, tool-proxy suite, TypeScript compilation, agent operating-contract tests, profile tests, agent-start tests, install-drift tests, adapter tests, workspace tests, and several capability-contract tests.

The memory-service suite ran with **35 passing tests**. The tool-proxy suite ran with **35 passing tests**. TypeScript compilation completed successfully in the earlier validation run.

### What failed in the broader CI-style run

The full PowerShell self-test sweep was not green in the current Linux PowerShell environment.

| Failure | Meaning |
|---|---|
| `Test-AgentJobHelpers.ps1` reported that the host home directory was mounted | This requires investigation of the test assertion and path normalization. It may be a test portability issue caused by Windows-style fixture paths and the Linux `USERPROFILE` environment, but the failure must not be ignored because it covers a security invariant. |
| `Test-Doctor.ps1` invoked `Get-CimInstance`, which is unavailable in the Linux PowerShell environment | The doctor process-ancestry implementation is Windows-specific. That is acceptable only if the command is explicitly Windows-only and CI does not pretend to validate it cross-platform. |

A test runner that counts failures but exits zero would also be a serious CI defect. The audit command intentionally captured `test_rc` without stopping so that all failures could be observed; the GitHub workflow itself needs to be checked whenever its shell behavior is changed.

### Measured Python coverage

Coverage was measured with `coverage.py` during this audit.

| Component | Tests | Statement coverage | Interpretation |
|---|---:|---:|---|
| `memory-service/app` | 35 passed | 69% | Important error, startup, persistence, embedding, and proxy branches remain untested. |
| `tool-proxy/app` | 35 passed | 91% | Strong relative coverage, but uncovered error and edge branches remain. |

Statement coverage is not a quality guarantee. The missing memory-service branches include startup and failure behavior that are particularly important for a local platform.

### What CI does not currently prove

The GitHub workflow runs PowerShell syntax checks and self-tests on Windows and Python tests on Ubuntu. It does not currently prove:

- `npm run compile` for the VS Code extension;
- Docker image build and worker execution;
- live Ollama, llama-server, vLLM, or LM Studio compatibility;
- real model acquisition from Hugging Face;
- free-VRAM detection against multiple NVIDIA generations;
- CPU-only, AMD, Intel, Apple Silicon, or WSL behavior;
- RAM mmap startup and performance thresholds;
- certificate invalidation after runtime or configuration drift;
- upgrade, uninstall, rollback, and interrupted-download recovery;
- memory-service restart and durable data recovery;
- cloud opt-in data-boundary tests;
- the root Python tester;
- VS Code extension behavior;
- cross-harness session resume under real CLIs;
- security scanning, dependency auditing, or secret-leak prevention in CI.

Therefore the current CI is a useful regression suite, not a universal compatibility proof.

## Required production test strategy

A credible public release needs a **capability matrix**, not a single green test run. Each matrix row must identify the operating system, CPU, RAM, GPU, driver, runtime version, model artifact hash, harness version, and observed verdict.

### Minimum hardware matrix

| Class | Required evidence |
|---|---|
| NVIDIA GPU, 8 GB VRAM | Chat fit, refusal or step-down behavior, coding refusal or CPU fallback, no unsafe overcommit. |
| NVIDIA GPU, 12–16 GB VRAM | Quant ladder selection, llama-server residency, live Pi contract, certificate scope. |
| NVIDIA GPU, 24 GB or more | Q4 or larger profile only after a new live contract; no inherited certificate. |
| CPU-only with 16–32 GB RAM | RAM mmap selection, startup, live contract, minimum throughput and timeout behavior. |
| Low-memory machine | Correct refusal, actionable message, no partial state or orphaned processes. |
| AMD and Intel GPU systems | Explicit supported or unsupported result; no false compatibility claim. |
| Apple Silicon macOS | Explicit supported or unsupported result; current implementation should be marked unsupported until ported and tested. |
| Windows and Linux | Separate install, lifecycle, path, process, firewall, and service evidence. |

### Minimum lifecycle and fault-injection suite

The system should test interrupted model downloads, corrupted artifacts, unavailable ports, rogue backends, stale certificates, expired certificates, runtime crashes, embedding-runtime failure, memory-service restart, malformed configuration, insufficient disk space, insufficient VRAM, insufficient RAM, Docker unavailable, network policy changes, and partially completed setup.

Each failure test should verify both the user-facing diagnosis and cleanup of owned resources. A test that only checks a refusal message is insufficient if the process or port remains alive.

### Minimum agent contract suite

The coding door needs a reproducible contract containing local file read, local file write, shell command, test execution, repair after a failing test, workspace-boundary enforcement, multi-turn context retention, tool-call serialization, timeout, cancellation, and resume after process restart. The contract result should be stored with model hash, runtime version, harness version, prompt version, tool schema hash, hardware identity, and timings.

A single 3/3 result is too small to support a public reliability claim. Release evidence should report repeated trials, confidence intervals or at least a clearly defined pass-rate threshold, and the exact conditions under which a certificate is valid.

## Priority remediation plan

### P0: make claims honest and make CI unambiguously green

1. Fix or isolate the `Test-AgentJobHelpers.ps1` host-home assertion failure. Add path-normalization tests for Windows and Linux PowerShell.
2. Mark `ai-doctor` process-ancestry diagnostics as Windows-only or implement a platform adapter using `Get-Process` and native process metadata where supported.
3. Make the CI workflow run `npm ci` and `npm run compile`.
4. Add a CI summary that fails the job whenever any test fails and publishes the failing test names.
5. Change public documentation from “any PC” as an achieved capability to “Windows-first; hardware-gated; compatibility matrix in progress.”

### P1: unify the product spine

1. Define a single canonical lifecycle API and state model for chat, coding, memory, and optional cloud routes.
2. Separate chat model configuration from coding-capability configuration so a chat fallback can never be interpreted as a coding-capable fallback.
3. Give every adapter an explicit maturity state: `live-verified`, `contract-tested`, `connectivity-tested`, `experimental`, or `unsupported`.
4. Make unsupported routes fail with a capability report instead of silently falling back to a weaker route.
5. Integrate or clearly classify the root tester, worker-image builder, optional adapters, historical plans, and VS Code extension.

### P2: expand evidence

1. Add integration tests for Docker build and worker execution.
2. Add memory-service failure and restart tests and raise its meaningful coverage above 85% before release.
3. Add model acquisition tests with local HTTP fixtures, checksums, retries, cancellation, and disk-space failures.
4. Add hardware-fixture tests for no GPU, low VRAM, high VRAM, CPU-only, and malformed telemetry.
5. Add live verification jobs on a small, documented hardware matrix.
6. Add dependency pinning and vulnerability scanning for Python and Node dependencies.
7. Add a release artifact containing machine-readable capability evidence and a compatibility table.

## Final judgment

The repository is not a failed design. It contains a strong foundation for a **monolithic, local-first, evidence-gated AI platform**, and it already demonstrates better honesty than many local-AI projects because it records known failures and refuses to inherit another machine’s certificate.

It is also not finished to the standard implied by recommending it broadly as a proven system for local coding, chatting, reasoning, thinking, and cloud-optional use on arbitrary hardware. The architecture needs one canonical lifecycle, the configuration needs stronger separation between chat and coding eligibility, the dead and experimental surface needs explicit classification, and the verification program needs hardware and live-runtime evidence.

The appropriate release gate is:

> **Do not publish “works on all machines.” Publish “works where the local capability contract passes, with support determined by the compatibility matrix.”**

That wording matches the strongest part of Airlock’s actual design: evidence wins, and a model or vendor label is never a substitute for a live proof.

## References

[1]: ../AGENTS.md "Airlock agent operating contract"
[2]: ../README.md "Airlock repository README"
[3]: 10-Product-Vision.md "Airlock product vision, goal, and objectives"
[4]: ../.github/workflows/ci.yml "Airlock continuous integration workflow"
[5]: adr/PENDING.md "Airlock pending work and evidence index"
[6]: ../config/models.json "Airlock local model registry"
[7]: ../config/policies/provider-policy.json "Airlock provider policy"
[8]: ../scripts/agent-job-helpers.ps1 "Airlock worker-job policy helpers"
[9]: ../scripts/Test-AgentJobHelpers.ps1 "Airlock worker-job helper tests"
[10]: ../scripts/profile-helpers.ps1 "Airlock profile and doctor helpers"
[11]: ../memory-service/app "Airlock memory-service implementation"
[12]: ../tool-proxy/app "Airlock tool-proxy implementation"
[13]: ../main.py "Airlock root local AI tester"
[14]: ../package.json "Airlock VS Code extension manifest"
[15]: ../scripts/Build-AirlockWorkerImage.ps1 "Airlock worker image builder"
[16]: ../scripts/Test-Doctor.ps1 "Airlock doctor self-test"
