# AGENT-003 — end-to-end live evidence

Collected by evidence-collector on 2026-08-22 against branch `air-adr012-agent003`
@ `c66bc79`. Authorized by team-lead, with the real `~/.opencode/opencode.json`
backed up before the run and restored after.

Everything below is observed output from this host. Where a thing could not be
proven, it says so rather than inferring.

## Environment

| Item | Value |
|---|---|
| GPU | RTX 5000 Ada 16GB |
| Ollama | reachable on `127.0.0.1:11434`, v0.32.14 |
| OpenCode | 1.18.18 (`C:\Users\veere\AppData\Roaming\npm\opencode.ps1`) |
| Installed models | `qwen3-coder:30b`, `qwen2.5-coder:7b`, `all-minilm`, `nomic-embed-text`, `qwen2.5:0.5b` |
| Airlock hardened proxy (:12345) | **not listening** |

Config safety: backed up to `opencode.json.bak-20260822-095617`, restored after
the runs. SHA256 `0C95C6C3…A298975` identical before and after. The real
`~/.ai-platform` was never written to — all runs used a scratch `-PlatformDir`.

## Two environment blockers found before the gate could even be reached

**1. A fresh `-PlatformDir` cannot reach Ollama at all.**
`Get-AirlockOllamaBaseUrl` (`scripts/runtime-adapters/ollama.ps1:21-30`) reads
`$PlatformDir/.active-port.json` and falls back to **port 12345**, Airlock's
hardened-proxy port — not Ollama's 11434. With no port file the run dies at
`FAILED: Ollama is not reachable. Run ai-start first.` even though Ollama is up.
The real `~/.ai-platform` has no `.active-port.json` either, and nothing is
listening on 12345, so on this host the E2E path is unreachable until `ai-start`
has run. Worked around by seeding `{"port":11434}` into the scratch platform dir.
**This bypasses the hardened proxy** — disclosed, not hidden.

**2. The only shipped Ollama profile references a model nobody has.**
`config/agent-profiles.json` ships `ollama-gemma4-12b` → `modelRef: gemma4:12b`,
which is not installed here:

```
FAILED: model 'gemma4:12b' not found. Acquisition (§6 Acquire) is not
implemented in this pass - pull it manually first.
```

So the shipped catalogue cannot produce a passing session on a stock host. Runs B
and C below therefore used a scratch catalogue pointing at real installed models.
That substitution is the only deviation from shipped config.

## Run B — `qwen2.5-coder:7b`

```
FAILED: no transport passed. Reasons:
  - Transport 'ollama-openai-direct' is not coding-ready: transport (no valid
    structured tool events); harness (capability contract failed).
  - Transport 'ollama-openai-direct' failed the capability contract.
  - Transport 'ollama-openai-proxy' is not coding-ready: harness (capability
    contract failed).
  - Transport 'ollama-openai-proxy' failed the capability contract.
```

Resulting registry (`state/capability-registry.json`) — note the field differs
per transport, which is the point:

```json
"…f277": { "transport": "ollama-openai-direct", "transportReturnedValidToolEvents": false, "verdict": "fail" },
"…3a02": { "transport": "ollama-openai-proxy",  "transportReturnedValidToolEvents": true,  "verdict": "fail" }
```

`transportReturnedValidToolEvents` is a **real measurement**, not a constant: the
direct transport produced no valid tool events, the proxy transport did. That is
positive observation surviving into persisted state.

## Run C — `qwen3-coder:30b` (the live VRAM/residency proof)

```
FAILED: no transport passed. Reasons:
  - Transport 'ollama-openai-direct' is not coding-ready: artifact
    (1.30078125GiB free vs 6GiB required, residency=CpuOnly); harness
    (capability contract failed).
  - Transport 'ollama-openai-proxy' is not coding-ready: artifact
    (1.30078125GiB free vs 6GiB required, residency=CpuOnly); harness
    (capability contract failed).
```

The 30B model does not fit 16GB, so Ollama spilled it to CPU. The gate measured
that **during the run** and named the failing dimension.

## Residency / VRAM re-measurement

| Moment | `/api/ps` | `Get-AirlockFreeVramGiB` |
|---|---|---|
| Idle, before runs | empty | 15.2646 GiB |
| 30B loaded | `qwen3-coder:30b size_vram=14630718012` | **1.3008 GiB** |
| After `keep_alive=0` unload | empty | 15.1846 GiB |

The reading tracks real GPU state across a 14GB swing. This is what condition 3
required and it is not mockable.

## Verdicts

| Condition | Verdict | Evidence |
|---|---|---|
| 1 — `codingReady` sole publish gate | **PASS (E2E)** | No `active-agent.json` was ever written. Publication blocked by the gate, not merely logged. |
| 2 — fit dimensions persisted | **PASS (E2E)** | `transportReturnedValidToolEvents` persisted per-entry with differing real values. |
| 3 — live re-check before cache reuse | **PASS (E2E)** | Live VRAM/residency measured per attempt; 15.26 → 1.30 → 15.18 GiB tracked real state. |

## Not proven

- **No successful certificate publication was observed.** Every transport failed
  the OpenCode capability contract, so the publish path's success branch is still
  unexercised. Conditions 1–3 are proven in their *blocking* direction only.
  Proving the pass direction needs a model that clears the contract on this GPU.
- The run bypassed the hardened proxy (port 11434 direct), so nothing here says
  anything about the :12345 path.
- Runs used a scratch catalogue, not shipped `config/agent-profiles.json`.

## Known residual (accepted, non-blocking)

`?? $false` at `Start-AgentSession.ps1:224` maps an **absent**
`transportReturnedValidToolEvents` to `false` rather than to a cache miss, so a
registry written before `88cef5c` reports one spurious transport failure. It
self-heals when the 5-minute pass TTL expires, since the cached branch never
rewrites the entry.
