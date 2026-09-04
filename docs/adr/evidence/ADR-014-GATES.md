# Gates: AIR-014 Agent operating contract

OWNS: CLAUDE.md, AGENTS.md, README.md (tool-calling section), config/opencode.json.template,
docs/08-Agent-CLI-Setup-Guide.md (supportsFunctionCalling wording + qwen2.5 tool-use example label),
docs/05-Provider-Fallback-Matrix.md (agentic note), CHANGELOG.md (new top entry),
scripts/Test-AgentOperatingContract.ps1, docs/adr/ADR-014-agent-operating-contract.md,
docs/superpowers/specs/2026-09-04-agent-operating-contract-design.md,
docs/superpowers/plans/2026-09-04-agent-operating-contract.md

Scope: make the files an agent reads first describe Airlock, and make user-facing
tool-calling copy match live evidence. No runtime/CLI/model-acquisition changes.

- [x] G1: Invariant test exists and failed on the pre-rewrite tree
      CHECK: python3 mirror of scripts/Test-AgentOperatingContract.ps1 against the pre-rewrite CLAUDE.md / template (pwsh not installed in this Linux session; the .ps1 is the CI artifact, same asserts)
      EXPECT: non-zero exit, at least one FAIL line naming CLAUDE.md and one naming opencode.json.template
      EVIDENCE: MET. First run against unmodified main contents: 20 FAILs, including "CLAUDE.md contains Airlock", "CLAUDE.md does not contain npm run build && npm test", "config/opencode.json.template does not set model to ollama/devstral-small-2:24b". README qwen3-coder:30b already present (PASS). Failure mode was unmet contract, not parse error.

- [x] G2: Invariant test passes on the branch HEAD
      CHECK: python3 /tmp/airlock-drafts/run_invariants.py (mirrors scripts/Test-AgentOperatingContract.ps1)
      EXPECT: exit 0, no FAIL lines
      EVIDENCE: MET. "All agent operating contract checks passed" (22 PASS / 0 FAIL) after the rewrites. CI will run the .ps1 on windows-latest.

- [x] G3: CLAUDE.md names the product and the real test runner
      CHECK: grep -c -i airlock CLAUDE.md; grep -c "npm run build && npm test" CLAUDE.md; grep -c -iE "pwsh|PowerShell" CLAUDE.md
      EXPECT: airlock ≥ 1, npm-run-build-and-test = 0, pwsh/PowerShell ≥ 1
      EVIDENCE: MET. airlock=2, npm=0, pwsh=2

- [x] G4: CLAUDE.md does not load Ruflo theater as the default product
      CHECK: grep -c "Agent Booster" CLAUDE.md; grep -c Darwin CLAUDE.md; grep -c Flywheel CLAUDE.md; grep -c MetaHarness CLAUDE.md
      EXPECT: all 0
      EVIDENCE: MET. booster=0 darwin=0 fly=0 meta=0

- [x] G5: Known-failed models are named as do-not-retry
      CHECK: grep -n "qwen2.5-coder:7b\|qwen3-coder:30b\|devstral-small-2:24b\|Do Not Retry\|do not retry" CLAUDE.md
      EXPECT: all three model ids present; a do-not-retry heading or phrase present
      EVIDENCE: MET. Line 30 "Do not retry these..."; lines 42-44 name all three models as known-failed / 0/6.

- [x] G6: opencode template default is not a known-failed agentic model
      CHECK: python3 -c "import json; print(json.load(open('config/opencode.json.template'))['model'])"
      EXPECT: not ollama/devstral-small-2:24b and not ollama/qwen2.5-coder:7b
      EVIDENCE: MET. ollama/qwen3-coder:30b (connection/chat default; CLAUDE.md and README say it is not agentic-ready)

- [x] G7: README agentic status matches models.json
      CHECK: grep -n "0/6\|inconsistent for agentic\|not solved" README.md
      EXPECT: at least one hit in the tool-calling section (near qwen3-coder:30b)
      EVIDENCE: MET. README.md:117 contains 0/6, agenticReliabilityNote, "inconsistent for agentic coding sessions, not solved"

- [x] G8: 08-guide no longer treats supportsFunctionCalling as a reliability verdict
      CHECK: grep -n "tells you upfront which models can reliably drive tool calls" docs/08-Agent-CLI-Setup-Guide.md
      EXPECT: 0 hits
      EVIDENCE: MET. 0 hits. Replacement language: "is a seed, not a live verdict — see each model's agenticReliabilityNote and ADR-012/ADR-014"

- [x] G9: Out of scope stayed out of scope
      CHECK: git diff origin/main --stat -- scripts/profile-helpers.ps1 scripts/Start-AgentSession.ps1 scripts/Get-ModelAcquisition.ps1 config/agent-profiles.json
      EXPECT: empty diff (those files are AIR-015/016)
      EVIDENCE: MET. empty diff
