#!/bin/bash
# Hermes agent entrypoint — runs inside the container
set -e

echo "=== Hermes Agent Container ==="
echo "Workspace: /workspace (read-only repo mount)"
echo "Output:    /workspace/output"
echo "Ollama:    $OLLAMA_HOST (from host)"
echo ""

MODELS_FILE="/home/hermes/.pi/agent/models.json"

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

exec pi --provider ollama-local --model devstral-small-2:24b