# Stop Hermes — clean up container and retrieve output files
param(
    [string]$OutputDir = "",
    [switch]$KeepVolume
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $OutputDir) {
    $OutputDir = "$env:USERPROFILE\source\repos\career-ops"
}

Write-Host ""
Write-Host "Stopping Hermes agent..." -ForegroundColor Yellow

docker compose -f "$ScriptDir\docker-compose.yml" down 2>$null

if (-not $KeepVolume) {
    Write-Host "Extracting output files..." -ForegroundColor Yellow
    $tempContainer = "hermes-output-extract"

    docker run --rm -v hermes-agent_hermes-output:/output alpine sh -c "chmod -R 777 /output" 2>$null

    docker run --rm -d --name $tempContainer -v hermes-agent_hermes-output:/output alpine sleep 30 2>$null
    Start-Sleep 2
    docker cp "${tempContainer}:/output/." $OutputDir 2>$null
    docker stop $tempContainer 2>$null

    Write-Host "Output files copied to: $OutputDir" -ForegroundColor Green
} else {
    Write-Host "Output volume preserved for next session." -ForegroundColor Green
}

Write-Host "Hermes agent stopped." -ForegroundColor Green
Write-Host ""