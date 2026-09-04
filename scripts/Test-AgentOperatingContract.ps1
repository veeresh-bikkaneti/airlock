# Invariant test for Airlock's agent operating contract (ADR-014).
# Reads files in the repo checkout only. Does not start Ollama, Docker, or any model.
# Run: pwsh -File scripts/Test-AgentOperatingContract.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing agent operating contract (ADR-014)..." -ForegroundColor Cyan

$claude = Get-Content (Join-Path $RepoRoot "CLAUDE.md") -Raw
$agents = Get-Content (Join-Path $RepoRoot "AGENTS.md") -Raw
$gemini = Get-Content (Join-Path $RepoRoot "GEMINI.md") -Raw
$copilotPath = Join-Path (Join-Path $RepoRoot ".github") "copilot-instructions.md"
$copilot = Get-Content $copilotPath -Raw
$templatePath = Join-Path (Join-Path $RepoRoot "config") "opencode.json.template"
$templateJson = (Get-Content $templatePath -Raw) | ConvertFrom-Json
$readme = Get-Content (Join-Path $RepoRoot "README.md") -Raw
$guide = Get-Content (Join-Path (Join-Path $RepoRoot "docs") "08-Agent-CLI-Setup-Guide.md") -Raw

# --- AGENTS.md is the portable contract ---

Assert-True ($agents -match 'Airlock') "AGENTS.md contains Airlock"
Assert-True ($agents -match 'Ollama') "AGENTS.md contains Ollama"
Assert-True (($agents -match 'PowerShell') -or ($agents -match 'pwsh')) "AGENTS.md contains PowerShell or pwsh"
Assert-True (-not $agents.Contains('npm run build && npm test')) "AGENTS.md does not contain npm run build && npm test"
Assert-True ($agents.Contains('pwsh -File') -or $agents.Contains('Test-*.ps1') -or $agents.Contains('scripts/Test-')) "AGENTS.md contains pwsh or Test-*.ps1 or scripts/Test-"

$qwen25 = "qwen2.5-coder:7b"
$qwen25At = $agents.IndexOf($qwen25)
$qwen25Window = ""
if ($qwen25At -ge 0) {
    $winStart = [Math]::Max(0, $qwen25At - 400)
    $winLen = [Math]::Min($agents.Length - $winStart, 800 + $qwen25.Length)
    $qwen25Window = $agents.Substring($winStart, $winLen)
}
Assert-True (($qwen25At -ge 0) -and ($qwen25Window -match 'unreliable|failed|known-failed|known failed')) "AGENTS.md contains qwen2.5-coder:7b with a nearby known-failed/unreliable indication"
Assert-True ($agents.Contains('devstral-small-2:24b')) "AGENTS.md contains devstral-small-2:24b"
Assert-True ($agents.Contains('qwen3-coder:30b')) "AGENTS.md contains qwen3-coder:30b"
Assert-True ($agents -match 'do not retry') "AGENTS.md contains do not retry"
Assert-True (-not $agents.Contains('Agent Booster')) "AGENTS.md does not contain Agent Booster"
Assert-True (-not $agents.Contains('Darwin')) "AGENTS.md does not contain Darwin"
Assert-True (-not $agents.Contains('Flywheel')) "AGENTS.md does not contain Flywheel"
Assert-True (-not $agents.Contains('MetaHarness')) "AGENTS.md does not contain MetaHarness"
Assert-True (($agents.Contains('structured tool_calls')) -or ($agents.Contains('structured tool'))) "AGENTS.md contains structured tool_calls or structured tool (Ollama is not the verified agentic default)"
Assert-True ($agents -match 'portable operating contract') "AGENTS.md names itself as the portable operating contract"

$agentsLower = $agents.ToLowerInvariant()
$airlockAt = $agentsLower.IndexOf('airlock')
$rtkAt = $agentsLower.IndexOf('rtk')
$airlockBeforeRtk = ($airlockAt -ge 0) -and (($rtkAt -lt 0) -or ($airlockAt -lt $rtkAt))
Assert-True ($airlockBeforeRtk) "AGENTS.md mentions Airlock before any rtk prefix rule"

# --- Adapters point at AGENTS.md and do not duplicate the ledger ---

Assert-True ($claude -match 'Airlock') "CLAUDE.md contains Airlock"
Assert-True ($claude.Contains('AGENTS.md')) "CLAUDE.md points at AGENTS.md"
Assert-True ($claude.Contains('@AGENTS.md')) "CLAUDE.md imports AGENTS.md with @AGENTS.md for Claude Code"
Assert-True (-not $claude.Contains('qwen2.5-coder:7b')) "CLAUDE.md does not duplicate the known-failed ledger (qwen2.5-coder:7b lives in AGENTS.md)"
Assert-True (-not $claude.Contains('npm run build && npm test')) "CLAUDE.md does not contain npm run build && npm test"
Assert-True (-not $claude.Contains('Agent Booster')) "CLAUDE.md does not contain Agent Booster"
Assert-True (-not $claude.Contains('Darwin')) "CLAUDE.md does not contain Darwin"
Assert-True (-not $claude.Contains('Flywheel')) "CLAUDE.md does not contain Flywheel"
Assert-True (-not $claude.Contains('MetaHarness')) "CLAUDE.md does not contain MetaHarness"

Assert-True ($gemini.Contains('AGENTS.md')) "GEMINI.md points at AGENTS.md"
Assert-True (-not $gemini.Contains('qwen2.5-coder:7b')) "GEMINI.md does not duplicate the known-failed ledger"
Assert-True ($copilot.Contains('AGENTS.md')) ".github/copilot-instructions.md points at AGENTS.md"
Assert-True (-not $copilot.Contains('qwen2.5-coder:7b')) ".github/copilot-instructions.md does not duplicate the known-failed ledger"

# --- config/opencode.json.template ---

$defaultModel = $null
if ($null -ne $templateJson.PSObject.Properties['model']) {
    $defaultModel = [string]$templateJson.model
}
Assert-True ($defaultModel -ne 'ollama/devstral-small-2:24b') "config/opencode.json.template does not set model to ollama/devstral-small-2:24b (known-failed for agentic)"
Assert-True ([string]::IsNullOrEmpty($defaultModel) -or (($defaultModel -ne 'ollama/devstral-small-2:24b') -and ($defaultModel -ne 'ollama/qwen2.5-coder:7b'))) "config/opencode.json.template default model, if present, is not ollama/devstral-small-2:24b or ollama/qwen2.5-coder:7b"

# --- README.md ---

$readmeHonesty = $readme.Contains('0/6') -or $readme.Contains('agenticReliabilityNote') -or $readme.Contains('inconsistent for agentic') -or $readme.Contains('not solved')
Assert-True ($readmeHonesty) "README.md contains 0/6 or agenticReliabilityNote or inconsistent for agentic or not solved"
Assert-True ($readme.Contains('qwen3-coder:30b')) "README.md contains qwen3-coder:30b"

$mentionsToolsBadge = ($readme.Contains('Tools badge')) -or ($readme.Contains('"Tools" badge'))
$badgeCaveat = ($readme -match 'not') -or $readme.Contains('unresolved') -or $readme.Contains('caveat') -or $readme.Contains('not yet proven') -or $readme.Contains('inconsistent')
Assert-True ((-not $mentionsToolsBadge) -or $badgeCaveat) "README.md does not claim the Tools badge as a sufficient fix without caveat"

# --- docs/08-Agent-CLI-Setup-Guide.md ---

Assert-True (-not $guide.Contains('tells you upfront which models can reliably drive tool calls')) "docs/08-Agent-CLI-Setup-Guide.md does not claim supportsFunctionCalling tells you upfront which models can reliably drive tool calls"
Assert-True (-not $guide.Contains('ollama/devstral-small-2:24b')) "docs/08-Agent-CLI-Setup-Guide.md does not still name ollama/devstral-small-2:24b as the template default"

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures agent operating contract check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All agent operating contract checks passed" -ForegroundColor Green
exit 0
