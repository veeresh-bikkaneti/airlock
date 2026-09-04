# Gates: AIR-015 Pi / Unsloth agentic path

OWNS: config/agent-profiles.json, hermes-container/Dockerfile,
hermes-container/entrypoint.sh, scripts/Invoke-PiCapabilityContract.ps1,
scripts/Test-PiCapabilityContract.ps1,
docs/adr/evidence/ADR-013-unsloth-*.md,
docs/adr/ADR-013-llama-cpp-pi-agentic-path.md

Scope: land the verified Pi + llama-server + Unsloth path. Do not edit AIR-014 files.

Ran from `/tmp/airlock/.worktrees/adr-015` on `feature/adr-015-pi-unsloth-agentic-path` at Task 1 commit `876533ec6bafb62a3fbf2f787db8acdef434e7ba`.

- [x] G1: profile promoted
      CHECK: python3 -c "import json; p=json.load(open('config/agent-profiles.json')); pr=next(x for x in p['profiles'] if x['profileId']=='llamacpp-qwen38-ud-q3-k-xl'); print(pr['candidateOnly']); raise SystemExit(0 if pr['candidateOnly'] is False else 1)"
      EXPECT: prints False, exit 0
      EVIDENCE: stdout=`False` exit=0 (EXPECT matched)

- [x] G2: CLAUDE.md untouched vs merge-base
      CHECK: git diff origin/main -- CLAUDE.md
      EXPECT: empty
      EVIDENCE: stdout empty, exit=0 (EXPECT matched)

- [x] G3: ConvertTo-AirlockCmdLineArg present with a test
      CHECK: grep -c ConvertTo-AirlockCmdLineArg scripts/Invoke-PiCapabilityContract.ps1 scripts/Test-PiCapabilityContract.ps1
      EXPECT: both files ≥ 1
      EVIDENCE: stdout=
      ```
      scripts/Invoke-PiCapabilityContract.ps1:2
      scripts/Test-PiCapabilityContract.ps1:4
      ```
      exit=0 (EXPECT matched; both ≥ 1)

- [x] G4: evidence docs present
      CHECK: test -s docs/adr/evidence/ADR-013-unsloth-pi-live-verification.md && test -s docs/adr/evidence/ADR-013-unsloth-fallback-GATES.md
      EXPECT: both exist and non-empty
      EVIDENCE: test -s both files, exit=0. Sizes: ADR-013-unsloth-pi-live-verification.md 13818 bytes; ADR-013-unsloth-fallback-GATES.md 4513 bytes. (EXPECT matched)

- [x] G5: AIR-014 / AIR-016 files not in the diff
      CHECK: git diff origin/main --name-only -- CLAUDE.md AGENTS.md README.md config/opencode.json.template scripts/profile-helpers.ps1 scripts/Start-AgentSession.ps1 scripts/Get-ModelAcquisition.ps1
      EXPECT: empty
      EVIDENCE: stdout empty, exit=0 (EXPECT matched)
