#!/bin/bash
# Hermes agent entrypoint — runs inside the container
set -e

echo "=== Hermes Agent Container ==="
echo "Workspace: /workspace (read-only repo mount)"
echo "Output:    /workspace/output"
echo "Ollama:    $OLLAMA_HOST (from host)"
echo ""

MODELS_FILE="/home/hermes/.pi/agent/models.json"

# ADR-012 §8.2: the OpenAI-compat endpoint is whatever the host's
# validated active-agent certificate proved capable (see
# run-hermes.ps1's Resolve-AirlockCertificateValidity), not a value this
# container picks on its own - patch it into the ollama-local provider
# before Pi ever reads models.json, replacing the file's baked-in default.
jq --arg baseUrl "$OPENAI_BASE_URL" '.providers."ollama-local".baseUrl = $baseUrl' "$MODELS_FILE" > "$MODELS_FILE.tmp" && mv "$MODELS_FILE.tmp" "$MODELS_FILE"

if [ -n "${NVIDIA_NIM_API_KEY:-}" ]; then
    echo "NVIDIA NIM: enabled (nemotron-ultra-253b, deepseek-v4-pro)"
    echo ""

    jq --arg nimKey "$NVIDIA_NIM_API_KEY" '
      .providers."nvidia-nim".apiKey = $nimKey
    ' "$MODELS_FILE" > "$MODELS_FILE.tmp" && mv "$MODELS_FILE.tmp" "$MODELS_FILE"
else
    echo "NVIDIA NIM: disabled (set NVIDIA_NIM_API_KEY to enable)"
    echo ""

    jq 'del(.providers."nvidia-nim")' "$MODELS_FILE" > "$MODELS_FILE.tmp" && mv "$MODELS_FILE.tmp" "$MODELS_FILE"
fi

echo "Models available:"
jq -r '.providers | to_entries[] | "  \(.key) (\(.value.name)): \([.value.models[]?.id] | join(", "))"' "$MODELS_FILE"
echo ""

# AIRLOCK_MODEL/AIRLOCK_PROFILE_ID come from the host's active-agent
# certificate via run-hermes.ps1 - the container never independently
# chooses a model. The devstral-small-2:24b default only applies to a
# standalone `docker compose run` that bypasses run-hermes.ps1 entirely.
echo "Profile:   ${AIRLOCK_PROFILE_ID:-unknown}"
echo "Model:     ${AIRLOCK_MODEL:-devstral-small-2:24b}"
echo ""

exec pi --provider ollama-local --model "${AIRLOCK_MODEL:-devstral-small-2:24b}"