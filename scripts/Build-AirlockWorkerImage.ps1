# Build-AirlockWorkerImage.ps1 — ADR-012 §9.2 (Phase F)
# Builds the airlock-worker:latest image that Start-AgentWorkerJob.ps1's
# Build-AirlockWorkerDockerArgs launches. No docker-compose here (unlike
# hermes-container/run-hermes.ps1) - that would produce a compose-derived
# image name (e.g. "airlock-worker-container-airlock-worker"), not the
# literal "airlock-worker:latest" Start-AgentWorkerJob.ps1's -ContainerImage
# default expects, so a plain `docker build -t` is the smaller, correct fit.
param(
    [string]$Tag = "airlock-worker:latest"
)

$ErrorActionPreference = "Stop"
$ContextDir = Join-Path (Split-Path -Parent $PSScriptRoot) "airlock-worker-container"

docker info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Docker is not running. Start Docker Desktop first." -ForegroundColor Red
    exit 1
}

Write-Host "Building $Tag from $ContextDir ..." -ForegroundColor Yellow
docker build -t $Tag $ContextDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED: docker build did not complete successfully." -ForegroundColor Red
    exit 1
}
Write-Host "SUCCESS: built $Tag" -ForegroundColor Green
exit 0
