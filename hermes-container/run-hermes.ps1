# Hermes Agent — Secure Setup Script
param(
    [string]$CareerOpsRepo = "",
    [string]$NimApiKey = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

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

# Airlock's own default is 12345, not Ollama's own default of 11434 - this
# used to hardcode 11434 and Hermes could never connect to an Airlock-managed
# Ollama as a result. Read the live port the same way tool-proxy does (a
# snapshot file, not a fixed value - Start-AI.ps1 adopts whatever port an
# already-running Ollama is on).
$OllamaPort = 12345
$activePortFile = "$env:USERPROFILE\.ai-platform\.active-port.json"
if (Test-Path $activePortFile) {
    try { $OllamaPort = (Get-Content $activePortFile -Raw | ConvertFrom-Json).port } catch { }
}

$ollamaRunning = $false
try {
    $c = [System.Net.Http.HttpClient]::new()
    $c.Timeout = [TimeSpan]::FromSeconds(5)
    $ollamaRunning = $c.GetAsync("http://127.0.0.1:$OllamaPort/api/tags").Result.IsSuccessStatusCode
} catch { }

if (-not $ollamaRunning) {
    Write-Host "WARNING: Ollama is not running on port $OllamaPort." -ForegroundColor Yellow
    Write-Host "Start it with: ai-start" -ForegroundColor Gray
}

# Tool-call proxy (opt-in, fixes unreliable tool-calling on small local models -
# see tool-proxy/app/main.py). Hermes runs Pi.dev, which declares tools, so
# route through the proxy when it's up; fall back to Ollama directly otherwise
# rather than hard-failing, same as every other opt-in component here.
$ToolProxyPort = 12347
$toolProxyRunning = $false
$toolProxyStateFile = "$env:USERPROFILE\.ai-platform\.tool-proxy-port.json"
if (Test-Path $toolProxyStateFile) {
    try { $ToolProxyPort = (Get-Content $toolProxyStateFile -Raw | ConvertFrom-Json).port } catch { }
}
try {
    $c = [System.Net.Http.HttpClient]::new()
    $c.Timeout = [TimeSpan]::FromSeconds(5)
    $toolProxyRunning = $c.GetAsync("http://127.0.0.1:$ToolProxyPort/health").Result.IsSuccessStatusCode
} catch { }

if ($toolProxyRunning) {
    $OpenAiPort = $ToolProxyPort
} else {
    $OpenAiPort = $OllamaPort
    Write-Host "WARNING: tool-proxy is not running on port $ToolProxyPort - Hermes will call Ollama directly." -ForegroundColor Yellow
    Write-Host "Tool calls from small models may come back as plain text. Start it with: ai-tool-proxy-start" -ForegroundColor Gray
}

$env:AIRLOCK_OLLAMA_PORT = "$OllamaPort"
$env:AIRLOCK_OPENAI_PORT = "$OpenAiPort"
$env:CAREER_OPS_REPO = $CareerOpsRepo
if ($NimApiKey) {
    $env:NVIDIA_NIM_API_KEY = $NimApiKey
    Write-Host "NVIDIA NIM: enabled" -ForegroundColor Green
} else {
    Write-Host "NVIDIA NIM: disabled (use -NimApiKey to enable)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Repo:    $CareerOpsRepo" -ForegroundColor White
Write-Host "Ollama:  http://host.docker.internal:$OllamaPort" -ForegroundColor White
Write-Host "Tools:   http://host.docker.internal:$OpenAiPort/v1 $(if ($toolProxyRunning) { '(via tool-proxy)' } else { '(direct - tool-proxy not running)' })" -ForegroundColor White
Write-Host ""

Write-Host "Building container..." -ForegroundColor Yellow
docker compose -f "$ScriptDir\docker-compose.yml" build --quiet

Write-Host ""
Write-Host "Launching Hermes agent..." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Your repo is mounted READ-ONLY at /workspace" -ForegroundColor Cyan
Write-Host "  Generated files go to /workspace/output (docker volume)" -ForegroundColor Cyan
Write-Host "  Type /exit to quit" -ForegroundColor Cyan
Write-Host ""

docker compose -f "$ScriptDir\docker-compose.yml" run --rm hermes-agent