# Airlock Canonical Lifecycle

Airlock is a **modular monolith** with one operational spine. Runtime adapters, model catalogues, memory services, and agent harnesses are replaceable components attached to this lifecycle. They are not separate product truths.

```text
request
  -> classify capability and privacy requirements
  -> inspect the current machine and workspace
  -> select a fitting profile
  -> acquire or verify the exact artifact
  -> start one owned runtime
  -> run the live contract for the requested capability
  -> publish a machine-scoped capability certificate only on pass
  -> expose the chat or coding door
  -> attach optional memory with an explicit degraded state
  -> stop owned resources and preserve evidence
```

## Lifecycle stages

| Stage | Required output | Failure rule |
|---|---|---|
| Request classification | Required capability, privacy boundary, workspace, and authorization | Refuse ambiguous high-impact requests. |
| Machine and workspace inspection | OS, CPU, RAM, GPU, free VRAM, paths, runtime availability, repository state | Do not infer hardware or workspace facts. |
| Profile selection | Exact model artifact, runtime, context, quantization, and harness | Never select an installed-but-unrequested coding candidate. |
| Acquisition | Verified artifact path, checksum or byte evidence, and available disk | Do not start from partial or unverified artifacts. |
| Runtime start | Owned process, endpoint, configuration hash, and health result | Clean up partial startup and refuse duplicate ownership. |
| Capability contract | Structured result for the requested capability | A metadata flag is not a live verdict. |
| Certificate publication | Machine/runtime/model/harness/config-bound evidence | Never inherit another machine's certificate. |
| Door exposure | Chat or coding endpoint with visible capability status | Do not expose coding tools from a chat-only verdict. |
| Memory attachment | Recall/remember status and service health | Passthrough must be visible as degraded, never silent amnesia. |
| Shutdown | Stopped processes, cleared active state, and audit record | Stop only resources Airlock owns. |

## Capability classes

Airlock must treat the following as separate capabilities:

- **Chat:** conversational completion and endpoint connectivity.
- **Coding:** multi-turn structured tool use, local workspace access, and repair-loop behavior.
- **Reasoning:** model-specific evaluation results for reasoning tasks.
- **Memory:** recall and persistence across turns and process restarts.
- **Cloud fallback:** explicit policy authorization, provider authentication, and data-boundary evidence.

A model may be suitable for chat while being unsuitable for coding. `supportsFunctionCalling` is a catalogue hint, not a coding certificate.

## Evidence states

Every runtime and harness integration must declare one of these states:

| State | Meaning |
|---|---|
| `live-verified` | A reproducible live contract passed under the recorded conditions. |
| `service-tested-live-path` | The service is exercised in the product path, but the complete capability is not certified. |
| `contract-tested` | Pure or mocked contracts pass; no live service proof exists. |
| `connectivity-tested` | An endpoint round trip passed; agentic reliability is not implied. |
| `experimental` | The path is available for development but not a release claim. |
| `unsupported-unverified` | The path must not be advertised as working. |

The machine-readable status source is [`config/compatibility-matrix.json`](../config/compatibility-matrix.json). The matrix is an evidence register, not a promise that every row works.

## Release rule

A release may advertise only the capabilities whose contracts pass on the target environment. The default user experience should show the current verdict and the next required check rather than silently downgrading from coding to chat or from local to cloud.
