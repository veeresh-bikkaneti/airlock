# Hermes Agent — Secure Setup Script
# ADR-012 §8.2: refuses to launch without a current, Pi/Hermes-compatible
# active-agent certificate rather than independently choosing an Ollama
# port, direct endpoint, proxy fallback, or model. The certificate is
# published only by a passing Start-AgentSession.ps1 run (see
# scripts/agent-state-helpers.ps1's Publish-AirlockActiveAgentCertificate)
# - this script never re-derives any of those decisions itself, it only
# reads what was already proven.
param(
    [string]$CareerOpsRepo = "",
    [string]$NimApiKey = "",
    [string]$AgentStatePath = "$env:USERPROFILE\.ai-platform\state\active-agent.json"
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot (not a hand-assigned $ScriptDir = Split-Path -Parent
# $MyInvocation.MyCommand.Path) - immune to being clobbered by
# agent-state-helpers.ps1 (or anything it dot-sources) reassigning the
# same variable name once dot-sourcing crosses into scripts/.
. (Join-Path $PSScriptRoot ".." "scripts" "agent-state-helpers.ps1")

if (-not $CareerOpsRepo) {
    $CareerOpsRepo = "$env:USERPROFILE\source\repos\career-ops"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Hermes Agent — Container Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $CareerOpsRepo)) {
    Write-Host "ERROR: Career-ops repo not found at: $CareerOpsRepo" -ForegroundColor Red
    Write-Host "Usage: .\run-hermes.ps1 -CareerOpsRepo <path>" -ForegroundColor Yellow
    exit 1
}

$dockerRunning = docker info 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Docker is not running. Start Docker Desktop first." -ForegroundColor Red
    exit 1
}

# Airlock's image is a Linux image. On Windows the supported reproducible
# deployment is Docker Desktop with the WSL2/Linux-container engine, not
# Windows containers and not a guessed host shell. Fail before certificate
# consumption or image build with an actionable diagnostic.
$dockerOs = (& docker info --format '{{.OSType}}' 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $dockerOs -ne 'linux') {
    Write-Host "ERROR: Airlock Docker containers require Docker Desktop's Linux/WSL2 engine." -ForegroundColor Red
    Write-Host "  Current Docker server OS: '$dockerOs'. Switch Docker Desktop to Linux containers and re-run." -ForegroundColor Yellow
    exit 1
}

$composeVersion = (& docker compose version 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $composeVersion) {
    Write-Host "ERROR: Docker Compose v2 is required (the 'docker compose' command)." -ForegroundColor Red
    Write-Host "  Update Docker Desktop, then re-run this command." -ForegroundColor Yellow
    exit 1
}

$ComposePath = Join-Path $PSScriptRoot "docker-compose.yml"
$composeCheck = & docker compose -f $ComposePath config --quiet 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Airlock Docker Compose configuration is invalid." -ForegroundColor Red
    Write-Host ($composeCheck | Out-String).Trim() -ForegroundColor Yellow
    exit 1
}

# --- ADR-012 §8.2: consume the active-agent certificate, never choose
# independently. A missing, expired, or harness-incompatible certificate
# refuses to launch rather than falling back to a guessed port/model -
# this replaces the old direct Ollama/tool-proxy reachability probes and
# their "fall back to direct Ollama" logic entirely; those decisions were
# already made, proven, and recorded when the certificate was issued. ---
$certificate = $null
if (Test-Path $AgentStatePath) {
    try { $certificate = Get-Content $AgentStatePath -Raw | ConvertFrom-Json } catch { $certificate = $null }
}
$validity = Resolve-AirlockCertificateValidity -Certificate $certificate -Now ([DateTime]::UtcNow) -CompatibleHarnesses @('pi-worker')
if (-not $validity.Valid) {
    Write-Host "ERROR: no valid Pi/Hermes-compatible agent certificate ($($validity.Reason))." -ForegroundColor Red
    Write-Host "  $($validity.Detail)" -ForegroundColor Yellow
    Write-Host "  Run: ai-agent-start -Harness pi-worker" -ForegroundColor Gray
    exit 1
}

$Model = $certificate.model
$EndpointUrl = $certificate.transport.endpoint
$ProfileId = $certificate.profileId
$Port = ([uri]$EndpointUrl).Port

# The certificate proves exactly one endpoint (direct or via proxy,
# whichever passed the capability contract) - both env vars point at that
# same proven endpoint, since there is no longer a second, independently-
# chosen port to disagree with it.
$env:AIRLOCK_OLLAMA_PORT = "$Port"
$env:AIRLOCK_OPENAI_PORT = "$Port"
$env:AIRLOCK_MODEL = $Model
$env:AIRLOCK_PROFILE_ID = $ProfileId
$env:CAREER_OPS_REPO = $CareerOpsRepo
if ($NimApiKey) {
    $env:NVIDIA_NIM_API_KEY = $NimApiKey
    Write-Host "NVIDIA NIM: enabled" -ForegroundColor Green
} else {
    Write-Host "NVIDIA NIM: disabled (use -NimApiKey to enable)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Repo:     $CareerOpsRepo" -ForegroundColor White
Write-Host "Profile:  $ProfileId" -ForegroundColor White
Write-Host "Model:    $Model" -ForegroundColor White
Write-Host "Endpoint: $EndpointUrl (proven $($certificate.transport.mode), certificate expires $($certificate.expiresAt))" -ForegroundColor White
Write-Host ""

Write-Host "Building container..." -ForegroundColor Yellow
docker compose -f $ComposePath build --quiet

Write-Host ""
Write-Host "Launching Hermes agent..." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Your repo is mounted READ-ONLY at /workspace" -ForegroundColor Cyan
Write-Host "  Generated files go to /workspace/output (docker volume)" -ForegroundColor Cyan
Write-Host "  Type /exit to quit" -ForegroundColor Cyan
Write-Host ""

docker compose -f $ComposePath run --rm hermes-agent
