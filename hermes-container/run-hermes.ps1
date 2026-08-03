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

$ollamaRunning = $false
try {
    $c = [System.Net.Http.HttpClient]::new()
    $c.Timeout = [TimeSpan]::FromSeconds(5)
    $ollamaRunning = $c.GetAsync("http://127.0.0.1:11434/api/tags").Result.IsSuccessStatusCode
} catch { }

if (-not $ollamaRunning) {
    Write-Host "WARNING: Ollama is not running on port 11434." -ForegroundColor Yellow
    Write-Host "Start it with: ollama serve" -ForegroundColor Gray
}

$env:CAREER_OPS_REPO = $CareerOpsRepo
if ($NimApiKey) {
    $env:NVIDIA_NIM_API_KEY = $NimApiKey
    Write-Host "NVIDIA NIM: enabled" -ForegroundColor Green
} else {
    Write-Host "NVIDIA NIM: disabled (use -NimApiKey to enable)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Repo:    $CareerOpsRepo" -ForegroundColor White
Write-Host "Ollama:  http://host.docker.internal:11434/v1" -ForegroundColor White
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