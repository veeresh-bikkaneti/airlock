# Gates: AIR-016 `ai-agent-start`

OWNS: scripts/profile-helpers.ps1, scripts/Start-AgentSession.ps1,
scripts/runtime-adapters/llamacpp.ps1, hermes-container/config/models.json,
huggingface-gguf acquire helper, scripts/Test-AgentStart.ps1

- [ ] G1: `ai-agent-start` exists
  CHECK: `rg -n "function global:ai-agent-start" scripts/profile-helpers.ps1`
  EXPECT: one definition forwarding to Start-AgentSession with default Unsloth profile + pi-worker

- [ ] G2: llama-server auto-starts
  CHECK: `rg -n "Start-LlamaCppRuntime" scripts/Start-AgentSession.ps1`
  EXPECT: production call (not only the "run it manually" error string)

- [ ] G3: GGUF acquire does not `ollama create`
  CHECK: new helper has no `ollama create`; mapper covers `unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL`
  EXPECT: dest `~/.ai-platform/models/Qwen3.8-27B-UD-Q3_K_XL.gguf`

- [ ] G4: Pi catalogue lists Unsloth id
  CHECK: python3 -c "import json; m=json.load(open('hermes-container/config/models.json')); ids=[x['id'] for x in m['providers']['ollama-local']['models']]; assert 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL' in ids"

- [ ] G5: unit tests
  CHECK: `pwsh -File scripts/Test-AgentStart.ps1` (and existing Test-StartAgentSession / Test-AgentProfileHelpers still pass)
  EXPECT: exit 0. No GPU required.
