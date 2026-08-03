# Provider Fallback Matrix

## Decision Table

| Scenario | Local available | Cloud fallback enabled | Secret available | Result |
|---|---:|---:|---:|---|
| Normal operation | Yes | No | N/A | Use local Ollama provider. |
| Local down, strict policy | No | No | Yes/No | Stop with clear error; do not use cloud. |
| Local down, cloud allowed, OpenRouter key exists | No | Yes | Yes | Use OpenRouter and log fallback reason. |
| Local down, OpenRouter missing, OpenAI key exists | No | Yes | Yes | Use OpenAI if it is next in priority order. |
| Local down, no provider keys available | No | Yes | No | Stop with error; fallback cannot proceed. |
| Local up, cloud keys present | Yes | Yes | Yes | Still use local by default unless user explicitly overrides policy. |

## Provider Mapping

| Provider | Key name | Endpoint | Notes |
|---|---|---|---|
| Ollama | none; use placeholder `ollama` for OpenAI-compatible clients | `http://127.0.0.1:<port>/v1` | Primary local path. |
| OpenRouter | `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1` | Good multi-model broker option. |
| OpenAI | `OPENAI_API_KEY` | `https://api.openai.com/v1` | Common fallback for OpenAI-compatible tooling. |
| Anthropic | `ANTHROPIC_API_KEY` | `https://api.anthropic.com` | May need provider-specific client settings. |
| Google | `GOOGLE_API_KEY` | `https://generativelanguage.googleapis.com` | Use adapter or provider-aware client when needed. |
| Azure OpenAI | `AZURE_OPENAI_KEY`, `AZURE_OPENAI_URL` | tenant-specific Azure endpoint | Requires deployment-specific configuration. |

## Recommended Priority
1. Ollama local.
2. OpenRouter.
3. OpenAI.
4. Anthropic.
5. Google.
6. Azure OpenAI.

## Rationale
- Local preserves privacy and reduces accidental data exposure.
- A broker such as OpenRouter can simplify multi-model fallback.
- Direct providers remain available when a broker is not desired.
- Azure OpenAI is often enterprise-specific and should remain explicitly configured.
