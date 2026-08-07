# install.ps1 — one-line installer for Airlock
# Usage: irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex
#
# Runs via `iex`, so it cannot rely on its own file path ($PSScriptRoot is empty
# when executed this way). It clones the repo to a fixed location and hands off
# to setup.ps1, which does the actual deployment — one codepath, not two.
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Installing Airlock" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: PowerShell 7+ required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Write-Host "Install it from https://github.com/PowerShell/PowerShell, then re-run this command in pwsh." -ForegroundColor Gray
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: git is required but not found on PATH." -ForegroundColor Red
    Write-Host "Install it from https://git-scm.com/, then re-run this command." -ForegroundColor Gray
    exit 1
}

$RepoUrl = "https://github.com/veeresh-bikkaneti/airlock.git"
$SrcDir = "$env:USERPROFILE\.airlock-src"

if (Test-Path "$SrcDir\.git") {
    Write-Host "Existing source found at $SrcDir — updating..." -ForegroundColor Yellow
    git -C $SrcDir pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: git pull failed. Delete $SrcDir and re-run this command for a clean clone." -ForegroundColor Red
        exit 1
    }
} else {
    if (Test-Path $SrcDir) {
        Write-Host "  $SrcDir exists but isn't a git repo — removing for a clean clone" -ForegroundColor Yellow
        Remove-Item $SrcDir -Recurse -Force
    }
    Write-Host "Cloning Airlock to $SrcDir..." -ForegroundColor Yellow
    git clone --depth 1 $RepoUrl $SrcDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: git clone failed." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "Running setup..." -ForegroundColor Yellow
& "$SrcDir\setup.ps1"
