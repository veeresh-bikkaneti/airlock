# Local-first agent fabric: detailed design specification

**Date:** 2026-08-20

**Status:** Proposed implementation specification for ADR-012

**Priority:** P0 — prerequisite for claiming local agentic coding works reliably.

**Scope:** Windows-first Airlock deployment; local-only model execution; no cloud model fallback.

## 1. Objective

Build an Airlock subsystem that can answer one operational question honestly:

> **Can this exact machine, model artifact, runtime, transport, harness, context limit, and sandbox policy complete a local coding task right now?**

The system must admit a profile only after it completes a real harness-specific workspace contract. It must work with more than one runtime and more than one local coding harness, but it must start with a small, testable support surface rather than creating an unbounded “all local models” promise.

The first usable path is:

```text
User chooses local profile
  → ai-agent-start
  → validated runtime adapter
  → real capability contract
  → active-agent certificate
  → OpenCode / Pi worker / Aider launch
  → optional OpenClaw job dispatch
  → isolated patch + test report
```

## 2. Product principles and invariants

| ID | Invariant |
|---|---|
| **I-01** | A model label, an Ollama `tools` tag, a benchmark, or a local-server 200 response never constitutes agent admission. |
| **I-02** | Every `coding-ready` or `worker-ready` profile has a current, versioned real-harness contract verdict. |
| **I-03** | A failed bootstrap never mutates a prior `active-agent.json`; only success atomically replaces it. |
| **I-04** | A profile cannot silently switch runtime, endpoint, model digest, effective context, template/parser, tool surface, or harness after proof. |
| **I-05** | The system never executes assistant JSON/XML/ReAct-looking text as a tool call unless the selected runtime/harness returned a validated structured tool event. |
| **I-06** | Coding and autonomous jobs run only in a dedicated worktree/sandbox. They do not modify the user’s current repository, home directory, global configuration, credentials, or browser session by default. |
| **I-07** | Cloud model fallback is disabled. A failure produces a precise local remediation rather than spending cloud tokens. |
| **I-08** | No global OpenCode configuration staging is concurrent. A lock and hash-guarded recovery transaction owns it for the full harness lifetime. |

## 3. Initial support matrix

The implementation must separate planned support from a final capability verdict.

| Runtime | OpenCode | Pi/Hermes worker | Aider | OpenClaw | Initial status |
|---|---|---|---|---|---|
| Ollama native `/api/chat` | N/A | N/A | N/A | Yes | **Experimental only**; OpenClaw-specific contract needed. |
| Ollama OpenAI-compatible `/v1` direct | Yes | Yes | Yes | Via custom provider only | **Baseline target.** |
| Ollama OpenAI-compatible `/v1` via Airlock proxy | Yes | Yes | Yes | Via custom provider only | **Baseline fallback target.** |
| `llama-server` OpenAI-compatible `/v1` | Yes | Yes | Yes | Via custom provider | **Experimental target.** Requires `--jinja` and template verification. |
| LM Studio OpenAI Chat/Responses | Yes | Yes | Yes | Via custom provider | **Experimental target.** Native tool template only. |
| vLLM / SGLang | Future | Future | Future | Via custom provider | **Lab-only.** No runtime promotion in this implementation. |
| OpenHands | Future | N/A | N/A | N/A | **Lab-only.** Separate container/project; not a 16 GB default. |

The matrix is a **routing and test plan**, not a compatibility claim. A cell becomes supported only after the associated contract suite passes on a version-pinned profile.

## 4. Model and hardware policy

### 4.1 No parameter-count shortcut

The selection algorithm uses free VRAM, model artifact bytes, runtime overhead, intended context, model residency, and measured contract behavior. It must not infer fitness from total system RAM, active parameter count, model-size branding, or a generic “4-bit” label.

Each local profile has three independent eligibility states:

| State | Meaning |
|---|---|
| `artifact-fit` | The artifact and configured context fit the selected GPU with the profile’s reserve. |
| `transport-fit` | The runtime/template/parser returns valid structured tool events for the profile contract. |
| `harness-fit` | A real requested harness completes the workspace contract under the selected sandbox policy. |

A profile becomes `coding-ready` only when all three are true.

### 4.2 Candidate catalogue for a 16 GB-class GPU

This table is an initial **download/benchmark order**, not an automatic fallback order.

| Profile candidate | Initial context | Role | Expected outcome |
|---|---:|---|---|
| `ollama/gemma4:12b` | 8K | Baseline native-tool candidate | First non-GGUF-specific benchmark; reported 7.6 GB artifact provides meaningful headroom. |
| `llama-server/qwen38-27b-ud-q3-k-xl` | 8K | Stronger experimental coding candidate | Direct GGUF/template control; requires a full contract. |
| `ollama/qwen38-27b-ud-iq4-xs` | 8K | Higher-quality experimental candidate | Try only after the Q3 profile establishes a stable baseline. |
| `ollama/gpt-oss:20b` | 4K–8K | Benchmark-only reasoning/tool candidate | Hardware floor is approximately 16 GB; never auto-promote on a 16 GB card. |
| Existing 15–18 GB Devstral/Qwen profiles | 4K–8K | Benchmark-only | May be useful but must demonstrate no unacceptable CPU offload and a passing contract. |

The profile installer asks for confirmation before any multi-gigabyte download. It never starts parallel model pulls.

## 5. New configuration and state

### 5.1 `config/agent-profiles.json`

This is source-controlled policy. It contains **candidates**, not passing verdicts.

```json
{
  "schemaVersion": 1,
  "profiles": [
    {
      "profileId": "ollama-gemma4-12b",
      "displayName": "Gemma 4 12B via Ollama",
      "runtime": "ollama",
      "transportCandidates": ["ollama-native", "ollama-openai-direct", "ollama-openai-proxy"],
      "modelRef": "gemma4:12b",
      "acquisition": { "kind": "ollama-pull", "requiresConfirmation": true },
      "initialContext": 8192,
      "minimumFreeVramGiB": 10,
      "toolSurface": "lean",
      "candidateOnly": true
    },
    {
      "profileId": "llamacpp-qwen38-ud-q3-k-xl",
      "displayName": "Qwen3.8 27B UD-Q3_K_XL via llama.cpp",
      "runtime": "llama-server",
      "transportCandidates": ["openai-direct"],
      "modelRef": "unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL",
      "acquisition": { "kind": "huggingface-gguf", "requiresConfirmation": true },
      "initialContext": 8192,
      "minimumFreeVramGiB": 14,
      "runtimeArgs": ["--jinja", "--flash-attn", "--n-gpu-layers", "all"],
      "toolSurface": "lean",
      "candidateOnly": true
    }
  ]
}
```

`minimumFreeVramGiB` is a policy floor. The runtime adapter must additionally verify actual placement during the contract; it cannot “force fit” a model that spills.

### 5.2 Capability registry

`state/capability-registry.json` is generated, user-local, and written atomically. Its evidence key is:

```text
SHA-256(
  contractVersion,
  profileId,
  modelRef,
  modelDigest,
  artifactHash,
  runtime,
  runtimeVersion,
  endpointMode,
  endpointIdentity,
  runtimeConfigHash,
  chatTemplateIdentity,
  effectiveContext,
  kvCacheMode,
  harness,
  harnessVersion,
  harnessConfigHash,
  toolSurfaceHash,
  sandboxPolicyVersion,
  proxyVersion
)
```

A profile never reuses an evidence entry that omits a component it claims to validate. For example, `proxyVersion` is `null` only in direct modes; in proxy mode it is a deterministic hash of deployed proxy application files and requirements.

```json
{
  "schemaVersion": 1,
  "entries": {
    "sha256:<evidence-key>": {
      "profileId": "ollama-gemma4-12b",
      "modelDigest": "sha256:<observed>",
      "runtime": { "name": "ollama", "version": "<observed>" },
      "transport": { "mode": "ollama-openai-direct", "endpoint": "http://127.0.0.1:12345/v1" },
      "effectiveContext": 8192,
      "harness": { "name": "opencode", "version": "<observed>" },
      "contractVersion": 1,
      "verdict": "pass",
      "passedTrials": 3,
      "provenAt": "2026-08-20T00:00:00Z",
      "expiresAt": "2026-08-20T00:05:00Z",
      "evidenceSummary": "redacted, bounded"
    }
  }
}
```

Pass and failure entries have distinct short TTLs. `-ForceVerify` bypasses both; `-NoCache` does not read or write them.

### 5.3 Active-agent certificate

`state/active-agent.json` is a success-only last-known-good certificate.

```json
{
  "schemaVersion": 1,
  "sessionId": "uuid",
  "profileId": "ollama-gemma4-12b",
  "model": "gemma4:12b",
  "modelDigest": "sha256:<observed>",
  "runtime": { "name": "ollama", "version": "<observed>" },
  "transport": { "mode": "ollama-openai-direct", "endpoint": "http://127.0.0.1:12345/v1" },
  "effectiveContext": 8192,
  "harness": "opencode",
  "capabilityEvidenceKey": "sha256:<evidence-key>",
  "sandboxPolicyVersion": 1,
  "provenAt": "2026-08-20T00:00:00Z",
  "expiresAt": "2026-08-20T00:05:00Z"
}
```

Only a successful bootstrap replaces this file. A failed candidate attempt records failure evidence but never invalidates or edits an unrelated valid certificate.

## 6. Runtime adapter contract

Create `scripts/runtime-adapters/` with one adapter per runtime. An adapter exposes these operations:

| Operation | Required behavior |
|---|---|
| `Discover` | Return installed models, runtime version, endpoint, and available capabilities without pulling models. |
| `Acquire` | Ask for confirmation; download/import exactly one requested profile artifact; wait for completion; verify digest/hash. |
| `Start` | Start or adopt the runtime on a loopback endpoint; return a process/port identity and runtime configuration hash. |
| `Inspect` | Return model identity, effective context, template/parser identity, GPU placement/residency evidence, and endpoint health. |
| `StopIfOwned` | Stop only a process created by the current session and verified by PID start time plus instance nonce. |

### 6.1 Ollama adapter

The Ollama adapter supports two distinct endpoint modes.

* `ollama-native` is for OpenClaw and uses `/api/chat`.
* `ollama-openai-direct` is for OpenCode, Pi, and Aider and uses `/v1`.
* `ollama-openai-proxy` starts the Airlock proxy only if the direct contract fails.

The adapter must obtain a model digest from the running Ollama model list/API and the effective context from the actual active runtime configuration. It must report whether the model is fully GPU-resident, partially offloaded, or CPU-resident during the capability run.

### 6.2 llama.cpp adapter

The llama.cpp adapter serves a direct GGUF and is intentionally explicit about template behavior. It starts `llama-server` with:

* loopback host and an Airlock-selected port;
* `--jinja`;
* the selected artifact/model alias;
* an explicit context limit;
* an explicit GPU-layer policy;
* a recorded KV-cache policy;
* a random process instance nonce;
* a JSONL or server audit location.

Before a tool contract it checks `/props` for the embedded or configured template identity. It must fail as `template_unverified` if the runtime cannot establish the tool-capable template/parser used by the request. The adapter does not turn generic JSON-looking responses into execution.

### 6.3 LM Studio adapter

The LM Studio adapter discovers the model ID via `/v1/models`, records server/build version and selected model identifier, and verifies that the runtime reports/uses a native tool template. It uses either Chat Completions or Responses API as recorded in the profile. It does not use LM Studio’s default/fallback tool format as a certification substitute; the real harness contract decides.

## 7. Bootstrap and real capability contracts

### 7.1 `Start-AgentSession.ps1`

Parameters:

```text
-Profile <profileId>
-Harness <opencode|pi-worker|aider|openclaw>
-Context <int>
-ForceVerify
-NoCache
-WhatIf
-WorkspaceRoot <path>              # only for an approved coding session
```

Behavior:

1. Acquire the single user-scoped bootstrap lock.
2. Resolve selected profile; never auto-select a candidate merely because it is already installed.
3. Check free VRAM and user confirmation for acquisition.
4. Start/adopt runtime with an exact profile configuration.
5. Inspect model/runtime/template/context/residency.
6. Read a fresh capability entry. If it is absent/stale, run the harness contract.
7. Try transport candidates in profile order. A proxy fallback is attempted only after direct failure.
8. On pass, atomically publish the active-agent certificate.
9. On failure, return every candidate/transport/trial reason and leave a prior certificate untouched.
10. Release the lock after all session-owned resources have been appropriately retained or cleaned up.

`-WhatIf` performs discovery and prints the plan only. It never starts a process, pulls a model, writes state, invokes a harness, or changes a global configuration.

### 7.2 Derived-value workspace contract

All coding-capable contracts share the following semantic test; each harness implements its own invocation wrapper.

1. Create a new disposable workspace inside Airlock’s temporary root.
2. Generate a cryptographically random 128-bit marker and write `MARKER=<value>` to `seed.md`. Never include the value in the prompt.
3. Create a validated, uniquely identified temporary harness configuration.
4. Run the real harness with this instruction:

   ```text
   Read seed.md. Create output.md containing exactly the value after MARKER=.
   Do not access files outside this workspace. Reply exactly DONE.
   ```

5. Assert process success, no out-of-workspace request, known configuration correlation, valid structured tool events as applicable, and exact `output.md` content.
6. Remove workspace and temporary harness configuration in `finally`.
7. Repeat three consecutive trials by default. Record per-trial latency, cold/warm state, residency, transport, and sanitized failure reason.

The contract is a pass only after all trials pass. A raw JSON tool object, a request for an external path, a plain-text fabricated tool request, absent output, or a tool-result-loop failure is a contract failure.

### 7.3 Harness wrappers

| Wrapper | Required contract behavior |
|---|---|
| `Invoke-OpenCodeCapabilityContract.ps1` | Run real `opencode run` with a session-owned staged config, selected model, and disposable workspace. Verify config correlation and restore global configuration transaction. |
| `Invoke-PiCapabilityContract.ps1` | Run Pi in a disposable workspace against the exact OpenAI-compatible endpoint; prove one read/write/tool-result loop. |
| `Invoke-AiderCapabilityContract.ps1` | Run Aider against the disposable Git workspace and verify a requested exact edit and non-interactive test command. |
| `Invoke-OpenClawCapabilityContract.ps1` | Run its model/smoke and a lean tool-surface workspace action through the selected native or custom provider. It must never use a messaging channel in the contract. |

Aider’s first contract is deliberately simpler: its job is reliable repo editing and testing, not exercising a generic function-call parser. It nevertheless runs inside the same workspace boundary.

## 8. Harness configuration ownership

### 8.1 OpenCode global configuration transaction

OpenCode lacks a suitable per-process endpoint/config override for the required route. `Start-AgentSession.ps1` therefore stages the global config through `scripts/Invoke-HarnessConfigTransaction.ps1`.

The transaction record includes: session ID, owner PID/start time, original-file existence, original hash, backup path, staged hash, global-config path, process launch time, and final restore result.

| Step | Requirement |
|---|---|
| Lock | Atomically create user-scoped lock; stale takeover requires a dead verified owner or explicit recovery. |
| Backup | Preserve original config byte-for-byte, or record `originalAbsent=true`. |
| Stage | Validate a complete local provider/model configuration, write to same-directory temporary file, and atomically replace the active config. |
| Run | Hold the lock for the full OpenCode process, not merely until launch. |
| Restore | Restore only if the current config hash equals the staged hash. Otherwise stop and preserve a recovery record rather than overwrite a user change. |
| Recover | `ai-opencode-recover` and `ai-doctor` identify orphaned transactions and require hash/ownership verification before recovery. |

No action silently writes `.opencode` configuration into a user project.

### 8.2 Pi/Hermes worker

Refactor `hermes-container/run-hermes.ps1` to accept `-AgentStatePath` and refuse a missing, stale, or incompatible certificate. It must not independently choose an Ollama port, direct endpoint, proxy fallback, or model. The container receives only the selected endpoint/model/profile values required for the session.

## 9. Bounded autonomous jobs

### 9.1 Job manifest

`state/jobs/<job-id>.json` is the only input that permits an autonomous worker launch.

```json
{
  "schemaVersion": 1,
  "jobId": "uuid",
  "profileEvidenceKey": "sha256:<approved capability key>",
  "task": "Implement the approved issue in the worktree and run the listed tests.",
  "repo": { "path": "C:\\source\\project", "ref": "main" },
  "allowedCommands": ["pnpm test", "pnpm lint", "git diff", "git status"],
  "network": "disabled",
  "credentials": "none",
  "maxWallClockMinutes": 45,
  "maxToolSteps": 80,
  "output": { "createBranch": true, "allowMerge": false, "allowPush": false }
}
```

### 9.2 Worker execution

`Start-AgentWorkerJob.ps1` creates a new Git worktree or a repository copy under an Airlock job directory and starts a non-admin, ephemeral Docker worker. The worker has:

* only the job worktree writable;
* a read-only tool policy supplied from the manifest;
* no Docker socket, host process access, browser session, secrets, or home-directory mount;
* network disabled by default;
* bounded CPU/RAM/wall clock/tool steps;
* an append-only redacted audit file and a final patch/test summary.

The worker can propose a branch/patch and test report. It cannot merge, push, deploy, send messages, alter global configuration, download dependencies, or enable network without a newly approved job manifest.

### 9.3 OpenClaw coordinator adapter

`OpenClaw` is optional and is never the default execution plane. Its adapter may create a job manifest only from an allowlisted local operator/channel and only for pre-approved job templates. It has no direct file-write, shell, secret, Git remote, or worker-container privilege. The dispatcher validates the request against the manifest schema before starting a worker.

For local-only OpenClaw, start with one model provider and `localModelLean` / a narrow tool surface. It requires a distinct contract per native Ollama and OpenAI-compatible provider route because those transports differ. The effective model context is the measured profile context—not the model card’s maximum or OpenClaw’s recommended high-context tier.

## 10. Tests and acceptance criteria

### 10.1 Unit tests

Add deterministic PowerShell tests for:

* profile schema validation and candidate explicit-selection rule;
* cache evidence-key mutation for every component;
* free-VRAM policy and no-CPU-offload agent promotion;
* atomic writes, recovery from torn state, and concurrent lock attempts;
* success-only active-agent state;
* staged global-config backup/hash/restore/recovery behavior;
* proxy ownership cleanup, direct-to-proxy fallback, and no-proxy-after-direct-pass;
* job-manifest schema, command allowlist, and denied escape attempts;
* `-WhatIf` no-mutation guarantee.

### 10.2 Local live acceptance suite

Every profile admission must execute the following on the actual target machine:

| Test | Pass condition |
|---|---|
| Runtime identity | Exact runtime/version/model digest/template/effective context and endpoint are observed. |
| Residency | Intended context is served without unacceptable CPU/layer offload. |
| Basic completion | Exact short answer succeeds. |
| Structured tool request | Runtime/harness returns a real structured tool event, not raw tool-looking text. |
| Workspace read/write | Three derived-value trials create exact `output.md` files inside their disposable workspaces. |
| Negative boundary | Out-of-workspace path attempt is denied/classified; no permissions are widened. |
| Recovery | Restart or stale-session state is rejected until revalidated. |
| Harness | The requested harness starts using the exact active-agent certificate. |
| Autonomous worker | A harmless approved fixture task changes only the job worktree and produces a patch/test report. |

No model is made default because a single text completion, benchmark, or tool label passed. The suite’s evidence is attached to the profile-promotion PR in redacted form.

### 10.3 CI posture

Mock tests run in regular CI. Live hardware acceptance is a manually invoked self-hosted Windows release gate, because a public GitHub runner does not provide the required local model, GPU, Ollama/LM Studio, or safely provisioned harnesses. The absence of a live runner must remain visible in documentation and release notes.

## 11. Local platform manager

### 11.1 Product boundary

Airlock is responsible for the full local lifecycle:

```text
Inspect PC → formulate alternatives → user confirms plan → install/import → validate
→ publish deployment → configure harness and memory → run bounded work → observe
→ re-plan when hardware, runtime, model, workload, or evidence changes
```

It is not responsible for guessing a user’s intent, installing everything it can find, transforming arbitrary assistant text into tool calls, providing unrestricted host autonomy, or silently using cloud services after a local failure. It is a **local operations manager plus agent safety/control plane**.

Every managed item belongs to one of five registries: `inventory`, `plans`, `artifacts`, `deployments`, and `agents`. Registries have schema versions, provenance, timestamp, owner, validation status, and rollback/recovery rules.

### 11.2 PC inventory and recommendation engine

Implement `Get-AICapabilityInventory.ps1` and `ai-inventory`. It emits a redacted JSON record and a human-readable report. The canonical inventory includes:

| Domain | Required observation |
|---|---|
| OS and privileges | Windows edition/build, architecture, current user, elevation availability, execution policy. |
| GPU | Vendor/model, driver/runtime version, total/free VRAM, usable compute backend, supported precision/features, active display reservation. |
| CPU and RAM | Logical/physical cores, instruction capabilities, total/free RAM. |
| Storage | Free space and filesystem on model cache, workspace, and state volumes; write/atomic-rename capability. |
| Runtime prerequisites | Installed Ollama/LM Studio/llama.cpp/vLLM/container engines, exact versions, health, ports, and owned processes. |
| Development harnesses | OpenCode, Pi/Hermes, Aider, Git, Python/Node, container runtime, virtualisation status. |
| Local network | Loopback availability, private LAN policy, firewall state relevant to Airlock-owned ports. |
| Existing assets | Locally installed models/artifacts/digests and prior capability/performance evidence. |

Inventory is read-only, local by default, and stored only in Airlock state with a bounded retention policy. It never uploads machine information or contacts a model registry merely to inspect the PC.

Implement `New-AIPlan.ps1` and `ai-plan -Goal <interactive-coding|agent-worker|local-rag|automation|throughput-node>`. The planner scores compatible profile candidates against observed resources, goal, artifact disk cost, expected VRAM reserve, required context, model/tool-template metadata, runtime/harness support, license notice, and local evidence. It emits **at least two viable alternatives** when available and explains exclusions. It never promotes a candidate because it is already downloaded, has the largest parameter count, or has a static `tools` label.

| Goal | First plan type | Example result |
|---|---|---|
| `interactive-coding` | Low-latency validated edge profile | A directly validated local engine/model plus OpenCode or Aider. |
| `agent-worker` | Quality profile plus sandbox worker | Validated profile, Pi/Hermes adapter, disposable worktree, job policy. |
| `local-rag` | Embedding/index service plus coding profile | Repository-scoped index, retrieval policy, memory retention policy. |
| `automation` | Bounded graph/job runner | Validated agent profile, schedule/event trigger, stop conditions, approval points. |
| `throughput-node` | Server-runtime profile | vLLM/TensorRT-LLM candidate only when inventory shows sufficient GPU headroom. |

### 11.3 Plan confirmation, installation, and rollback

`ai-apply-plan -Plan <planId> -Confirm` is the only action that changes the machine. It displays the exact engine package/version, source URL or registry reference, model artifact/quant, expected download size, state/config paths, ports, installed plugin/skill manifests, required permissions, validation tests, and rollback action before execution.

The plan executor performs one component at a time:

1. Acquire an Airlock installation lock and re-check inventory assumptions.
2. Install or update the selected engine through a version-pinned adapter; verify package provenance/signature/hash when the upstream provides it.
3. Pull/import one user-approved artifact; persist registry source, digest/artifact hash, size, license notice, and acquisition time.
4. Write only Airlock-owned configuration; global harness staging remains a separately locked, restorable transaction.
5. Start the engine on a loopback-owned port and run runtime, capability, residency, and benchmark contracts.
6. Publish the deployment only on pass. If any step fails, stop session-owned processes and restore Airlock-owned configuration without deleting user-owned models or installations.

The executor may recommend a separate user action when an OS driver, BIOS setting, commercial license, or administrator-only installation is required; it does not bypass a confirmation or privilege boundary.

### 11.4 Engine, artifact, and harness adapters

Engine adapters use the existing lifecycle interface: `Discover`, `Acquire`, `Start`, `Inspect`, and `StopIfOwned`. They add `EstimateFit`, `ExportEvidence`, and `RollbackOwnedChange`.

| Adapter class | Initial implementations | Non-negotiable rule |
|---|---|---|
| Engine | Ollama, `llama-server`, LM Studio; vLLM for qualifying throughput nodes | Runtime, version, template/parser, context, and endpoint become part of evidence identity. |
| Artifact | Ollama model registry; explicit Hugging Face GGUF artifact; later engine-native model stores | Only explicit version/digest/quant sources are installed; model cards are metadata, not validation. |
| Harness | OpenCode, Pi/Hermes, Aider, OpenClaw; additional coding CLIs after contract | Harness consumes `active-agent.json`; it cannot choose an unknown default model or endpoint. |
| Agent framework | LangGraph first; future adapters only after durable-state/tool contract | Framework orchestrates state and policy; it is never treated as a model provider. |
| Automation product | OpenClaw/Hermes and named third-party adapters | Unknown or ambiguous names such as “Buzz” remain unintegrated until upstream identity, API/process contract, permissions, and real test are recorded. |

A harness configuration is always session-scoped when the harness allows it. Where it does not, Airlock uses the existing byte-for-byte global configuration staging transaction with exclusive lock, hash-guarded restoration, recovery tooling, and no project-file pollution.

### 11.5 Memory, RAG, and context management

Airlock’s context subsystem is a collection of purpose-specific local stores, not a single growing chat transcript.

| Layer | Backing store for a single PC | Purpose | Write authority |
|---|---|---|---|
| Ephemeral run context | Process memory plus bounded session record | Immediate model messages, tool results, cancellation state. | Active job only. |
| Durable graph checkpoints | SQLite initially; PostgreSQL at multi-worker scale | Resume/review agent state after interruption. | Orchestrator/checkpointer only. |
| Repository RAG index | Existing memory service/vector index with Git-ref and chunk provenance | Retrieve relevant code/docs rather than inject whole repositories. | Indexer after approved repository change detection. |
| Durable user/project memory | SQLite structured records plus optional embeddings | Explicit preferences, decisions, accepted facts, lessons. | User or approved deterministic extractor with provenance. |
| Evaluation/audit store | Append-only redacted local log | Profile results, tool approvals, job/patch/test outcomes. | Airlock control plane only. |

A memory record must have `scope`, `source`, `createdAt`, `expiresAt` or retention class, `confidence`, and `reviewState`. The model may propose memory, but cannot write a durable fact from its own output without a user/approved extractor and provenance. Repository RAG is scoped to repository/ref/branch and uses hybrid retrieval when available; retrieval is bounded by token budget and source citations. It must not silently mix unrelated projects or secrets into the next agent prompt.

`ai-context-status`, `ai-memory-search`, `ai-memory-forget`, `ai-rag-index`, and `ai-rag-prune` expose local user control. Context compaction produces a versioned summary with source ranges, budget, and expiration; original audited facts remain separately addressable. A summary is not permanent memory by default.

### 11.6 Agent and skill builder

An Airlock agent is an immutable, versioned manifest:

```yaml
agentId: code-fix-worker
version: 1.0.0
profileRequirement: quality / coding-ready
orchestrator: langgraph@<pinned-version>
workflow: workflows/code-fix-worker.yaml
memoryScopes: [repo:current, project:approved-decisions]
tools:
  - workspace-read
  - workspace-write
  - test-command
skillDependencies:
  - git-worktree@1.0.0
budgets:
  maxToolSteps: 80
  maxWallClockMinutes: 45
  maxOutputTokens: 24000
sandboxPolicy: worktree-no-network-v1
approvalPolicy: require-approval-for-network-and-git-push
outputContract: patch-and-test-report
```

The agent builder validates manifest schema, validates every requested tool against sandbox policy, resolves only pinned skill/plugin dependencies, records an immutable manifest digest, and requires a harmless fixture test before publication. It may generate a draft graph/workflow, but a developer/user must review the final manifest and requested permissions. LangGraph supports persistent checkpointed state and deterministic plus model-driven nodes; Airlock uses these features to constrain an agent loop rather than letting a general-purpose agent run indefinitely. [14] [15]

A skill/plugin manifest declares name, semantic version, publisher/source, hash/signature if available, instructions, executable files, dependencies, test fixture, tool scopes, network/credential requirement, uninstall/rollback action, and compatibility range. Downloaded text or agent-generated files are quarantined as data until the manifest is approved. A skill cannot self-install, add host-admin permissions, modify the platform policy, or invoke tools outside the published agent manifest.

### 11.7 Agent graphs, loops, and approvals

The initial LangGraph-backed orchestrator has explicit graph states:

```text
queued → preparing → retrieving → planning → executing-tool → validating
       ↘ waiting-approval ↗              ↘ retrying → failed
                                      → succeeded | cancelled | budget-exceeded
```

Every graph transition is persisted. The loop has a finite maximum number of model turns/tool calls, wall-clock deadline, retry/backoff limit, and a deterministic terminal condition. LLM output is used only to choose actions inside the typed tool and graph policy; deterministic nodes handle job creation, workspace setup, RAG indexing, test execution, state persistence, retry classification, and cleanup.

Approval interrupts are required for network access, new dependency installation, credentials, email/messages, changing permissions, pushing/merging Git, deployment, access outside the worktree, and any host-admin operation. The reviewer may approve, edit, reject, or supply a response. Rejected actions become explicit tool results; they are never silently executed on a retry. [17]

### 11.8 Automation adapters and durable job execution

One local SQLite-backed job queue handles schedules, manual actions, repository events, and adapter requests. A trigger creates a typed job manifest, reserves an eligible validated deployment through the gateway, and starts a sandboxed worker. It does not invoke a raw LLM prompt directly.

| Trigger/adapter | Allowed role | Default restrictions |
|---|---|---|
| Scheduler | Deterministic maintenance or approved bounded agent job | Explicit recurrence, missed-run policy, max concurrency 1 per job key. |
| Repository event adapter | Re-index, test, or create a draft job | Watches only approved local workspaces; no automatic push/merge. |
| OpenClaw | Local coordination/request intake | Allowlisted local source; it requests manifests but receives no direct shell/credential/worker control. |
| Hermes/Pi | Sandboxed task execution | Receives a validated profile certificate and a dedicated worktree only. |
| Buzz/other product | Future adapter | Blocked until a named upstream integration contract and safety test are implemented. |

On a local PC, the engine, gateway, indexer, and queue run as Airlock-owned user services/tasks only after user installation approval. They bind to loopback in single-PC mode. The PC must be on for local automations to run; a system that is asleep/offline is not silently replaced with cloud inference. Private-LAN worker mode is an explicit later deployment with authenticated encrypted registration, never a default exposure.

## 12. Throughput-oriented local inference plane

### 12.1 Scope and performance truth

Airlock must optimize two distinct outcomes:

* **Interactive latency:** time to first token (TTFT), smooth inter-token latency, cancellation responsiveness, and the reliability of one developer’s active coding session.
* **Aggregate throughput:** useful tokens and completed agent jobs per unit time across multiple independent sessions.

A 16 GB local GPU can be a fast **edge developer node**, but it cannot reproduce the throughput of a multi-GPU cloud fleet by loading an oversized model, running multiple model servers, or advertising an architecture-level context limit. The edge target is one persistent quality model and a small fast model only when measured residency permits it; quality agent generations are serialized and background jobs queue. The production scale target is a self-hosted GPU pool, not a second uncontrolled local process.

### 12.2 `agent-gateway` service

Implement `agent-gateway` as a local FastAPI service, reusing the repository’s tested Python service conventions. It is a control plane and streaming router, **not** a tool-call text repairer. It never turns assistant text into a tool event.

In edge mode it binds only to `127.0.0.1` and starts as a Windows user service/task after explicit installation. It persists only on the user’s own local workstation, where the GPU is available; a hosted control plane cannot perform local GPU inference. It exposes a stable OpenAI-compatible route for validated local consumers and an Airlock-management API:

| Endpoint class | Function |
|---|---|
| `POST /v1/chat/completions` | Stream a request to a selected validated deployment. Preserve structured tool events transparently. |
| `GET /v1/models` | List only currently healthy validated deployment profiles, not every locally downloaded model. |
| `POST /v1/responses` | Optional later compatibility endpoint; it is not a prerequisite for OpenCode. |
| `POST /internal/sessions` | Create a session with caller identity, deployment pool, priority, trust/cache boundary, and a certificate reference. |
| `POST /internal/workers/register` | Authenticated worker registration; disabled in edge mode. |
| `GET /internal/metrics` | Redacted Prometheus/OpenTelemetry-compatible metrics. |
| `POST /internal/cancel/{requestId}` | Propagate cancellation to an active compatible runtime. |

The existing `tool-proxy` remains a per-profile fallback translator behind a worker. It does not become the gateway and must not receive traffic for a direct profile that passed a real contract.

### 12.3 Deployment profiles and routing

Add `config/deployments.json` as source-controlled desired state, and `state/deployments.json` as observed state. A deployment references a capability evidence key and is ineligible until its worker passes health, artifact identity, runtime-version, and effective-context checks.

```json
{
  "schemaVersion": 1,
  "deployments": [
    {
      "deploymentId": "edge-fast-gemma4-12b",
      "pool": "fast",
      "evidenceKey": "sha256:<validated-profile-key>",
      "replicas": 1,
      "maxActiveSequences": 1,
      "priority": "interactive",
      "cacheTrustScope": "local-user-workspace",
      "admission": { "maxQueueWaitSeconds": 10, "maxPromptTokens": 8192 }
    },
    {
      "deploymentId": "edge-quality-qwen38",
      "pool": "quality",
      "evidenceKey": "sha256:<validated-profile-key>",
      "replicas": 1,
      "maxActiveSequences": 1,
      "priority": "interactive-and-background",
      "cacheTrustScope": "local-user-workspace",
      "admission": { "maxQueueWaitSeconds": 120, "maxPromptTokens": 8192 }
    }
  ]
}
```

The gateway selects only a compatible deployment by pool, tool contract, required context, model modality, sandbox policy, and health. It pins a continuing agent session to the same worker when doing so preserves reusable KV cache. New sessions select the least-loaded compatible replica. It does not randomly round-robin requests that share a repository/system/tool prefix.

### 12.4 Queues and service classes

Use a durable local SQLite queue initially, with in-memory streaming state. A job is never lost on gateway restart; it is returned to `queued` or `failed-retryable` after an ownership/lease check. Keep the initial scheduler intentionally simple:

| Class | Callers | Admission rule | Preemption rule |
|---|---|---|---|
| `interactive` | OpenCode, Aider, direct user session | Small bounded queue; reject with a visible busy error rather than silently downgrading model. | May preempt admission of a new background prefill; never cut off an active stream. |
| `background` | Hermes worker, approved autonomous manifest | One job at a time on a 16 GB quality worker; explicit queue position and deadline. | Waits while interactive work is active or admission is reserved. |
| `maintenance` | Warm-up, benchmark, model validation | Runs only when no interactive or approved background work is active. | Always yields. |

Rate limiting, request cancellation, `max_tokens`, prompt-size limits, per-session tool-step budgets, and maximum wall-clock duration are mandatory at the gateway. A local agent cannot occupy a worker indefinitely merely because it is local.

### 12.5 Runtime progression

| Tier | Runtime choice | Why | When it is appropriate |
|---|---|---|---|
| Edge development | Ollama, `llama-server`, or LM Studio | Simple model residency and direct local debugging. | One user and one active quality generation. |
| First high-throughput node | vLLM | Continuous batching, chunked prefill, prefix caching, speculative decoding, structured tool/reasoning support, and broad parallelism options are documented. [10] | A GPU with enough VRAM for model weights plus KV cache and concurrent sequences. |
| NVIDIA performance appliance | TensorRT-LLM | In-flight batching, paged attention, speculative decoding, and multi-GPU/multi-node execution on NVIDIA hardware. [11] | Dedicated NVIDIA hardware and willingness to maintain a more specialized serving stack. |
| Cluster optimization | SGLang or vLLM distributed serving | Profile data may eventually justify separate prefill and decode capacity. [12] | Sustained concurrency and networking/KV-transfer capacity, not a single 16 GB laptop GPU. |

The Airlock runtime adapter owns launch arguments and captures them in the evidence key. For a serving runtime, the key includes server image/build, quantization, tensor/data/expert parallel topology, max model length, GPU-memory utilization target, cache policy, model/template/parser, and tool parser. A new server flag or image invalidates agent and performance evidence until re-tested.

### 12.6 Cache and batch rules

Prefix caching is enabled only after the gateway can isolate cache reuse by user/workspace trust boundary. For vLLM, use per-request `cache_salt` derived from a non-reversible `userId + workspaceId + profileId + sessionEpoch` HMAC. Do not use a raw user ID as a cache salt. vLLM documents cache salting as protection against timing-based cross-tenant inference. [13]

The cache identity contains model artifact, runtime/template/parser, normalized system prompt, tool schema set, repository map version, and sandbox policy. It is invalidated on any identity change. Long repository context is prepared once per session and reused through a worker-local session/prefix cache when possible; it is not re-sent to an unrelated random replica.

Continuous batching is a **server-runtime** feature. It is not simulated by firing parallel requests at Ollama or by launching a second model on the same edge GPU. Chunked prefill and speculative decoding are profile options; they are enabled only when a benchmark shows improved p95 latency and no regression in the workspace-tool contract.

### 12.7 Worker-pool protocol and self-hosted scale-out

A remote worker is a separate trusted, self-owned GPU machine—not an arbitrary discovered endpoint. A worker registration contains a mutually authenticated identity, allowed deployment IDs, runtime/model/profile evidence, health interval, capacity, and metrics endpoint. The control plane uses TLS, short-lived signed worker credentials, explicit allowlists, and per-user request authentication. It is never exposed directly to the Internet.

Scale out in this order:

1. Improve model residency/context/headroom on the primary GPU.
2. Add same-profile **replicas** and session affinity across a private LAN.
3. Use data-parallel request distribution for independent sessions.
4. Introduce multi-GPU tensor/expert/pipeline parallelism only where a model cannot fit in one node or profiling proves it is necessary.
5. Consider prefill/decode disaggregation only with sustained long-context concurrency and suitable high-speed KV transfer. SGLang documents that prefill is compute-intensive while decode is memory-intensive; this is a cluster optimization, not an edge feature. [12]

OpenClaw and Hermes are gateway clients. They must not scan ports, select a worker, change a deployment, or bypass quotas. A coordinator dispatches an approved job manifest; the gateway reserves an eligible quality worker; the sandbox worker returns a patch/test report.

### 12.8 Benchmark and promotion protocol

Implement `Invoke-InferenceBenchmark.ps1` plus a Python benchmark runner. It uses a versioned, redacted representative workload with these categories: short interactive edit, warm continuation with the same tool schema, repository-map prefill, structured tool call, three-trial derived-value workspace contract, background fixture task, and cancellation.

Record at least:

| Metric | Promotion use |
|---|---|
| TTFT p50/p95 | Interactive responsiveness. |
| Inter-token latency p50/p95 and delivered tokens/s | Streaming quality; do not report only average tokens/s. |
| Prefill tokens/s, prompt size, cache hit rate | Determines repository-context efficiency. |
| Queue wait p50/p95, active sequences, cancellations | Determines whether the node is actually overloaded. |
| GPU utilization, VRAM, KV cache occupancy, CPU offload | Validates deployment fit. |
| Tool parse/tool-loop/workspace-contract success | Prevents a throughput optimization from breaking agent behavior. |
| Cold start and model reload time | Identifies model churn and startup regressions. |

Promotion requires two comparisons: cold and warm. A candidate must meet the fixed agent correctness gate before it competes on performance. There is no universal tokens-per-second target; Airlock records the baseline for the user’s exact hardware/model/context and adopts a candidate only when it improves the chosen service-class objective without regressing p95 or correctness.

## 13. Delivery phases

| Phase | Deliverable | Exit gate |
|---|---|---|
| **A** | State/lock/config-transaction helpers | Unit suite passes; hash-guarded recovery demonstrated. |
| **B** | Ollama OpenAI direct + proxy profile contract for OpenCode | One candidate completes the three-trial OpenCode contract. |
| **C** | Pi/Hermes worker consumes active certificate | Live container test uses no independent model/endpoint fallback. |
| **D** | `llama-server` adapter | GGUF profile completes profile-specific tool/template contract. |
| **E** | LM Studio adapter | Native-tool model completes contract; parser/version recorded. |
| **F** | Job-manifest worker | Fixture task is sandboxed and produces only an unmerged patch. |
| **G** | OpenClaw coordinator adapter | Local-only, lean, allowlisted job dispatch passes without host tool escalation. |
| **H** | Local `agent-gateway`, deployment registry, queues, and metrics | Edge profile passes cold/warm benchmark and interactive/background isolation tests. |
| **I** | Self-hosted worker-pool registration and cache-aware routing | Two trusted replicas preserve session affinity, request isolation, cancellation, and profile admission. |
| **J** | vLLM serving-node adapter | A qualifying GPU server passes agent correctness and throughput promotion benchmarks. |

Do not start phases D–J by weakening B’s capability requirements. The architecture expands by proven cells in the support matrix.

## 14. Non-goals

This specification does not make OpenClaw a remote-access daemon, permit autonomous Git pushes/merges, promise OpenHands operation or cloud-like multi-user throughput on a 16 GB GPU, implement parallel tool calls before PROXY-002 is fixed, or silently use cloud providers when local execution fails. It does not claim that a gateway, batching feature, or a larger context setting can make an under-resourced model profile fit GPU memory.

## References

[1]: https://docs.openclaw.ai/providers/ollama "OpenClaw Ollama provider"
[2]: https://docs.openclaw.ai/gateway/local-models "OpenClaw local-model deployment guidance"
[3]: https://lmstudio.ai/docs/developer/openai-compat/tools "LM Studio tool use"
[4]: https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md "llama.cpp function calling"
[5]: https://github.com/openclaw/openclaw "OpenClaw security overview"
[6]: https://ollama.com/library/gemma4 "Gemma 4 in Ollama"
[7]: https://developers.openai.com/cookbook/articles/gpt-oss/run-locally-ollama "gpt-oss local Ollama guide"
[8]: https://docs.openhands.dev/openhands/usage/llms/local-llms "OpenHands local LLM guidance"
[9]: https://aider.chat/docs/llms/ollama.html "Aider local Ollama integration"
[10]: https://docs.vllm.ai/en/latest/ "vLLM serving capabilities"
[11]: https://nvidia.github.io/TensorRT-LLM/overview.html "TensorRT-LLM production serving overview"
[12]: https://docs.sglang.ai/advanced_features/pd_disaggregation.html "SGLang prefill/decode disaggregation"
[13]: https://docs.vllm.ai/en/stable/design/prefix_caching/ "vLLM prefix caching and cache isolation"
[14]: https://docs.langchain.com/oss/python/langgraph/persistence "LangGraph persistence"
[15]: https://docs.langchain.com/oss/python/langgraph/overview "LangGraph durable orchestration"
[16]: https://docs.langchain.com/oss/python/deepagents/retrieval "LangChain retrieval and RAG"
[17]: https://docs.langchain.com/oss/python/langchain/human-in-the-loop "LangChain human-in-the-loop tool approval"
