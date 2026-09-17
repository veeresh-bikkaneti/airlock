# install.ps1 — one-line installer for Airlock
# Usage: irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex
#
# Runs via `iex`, so it cannot rely on its own file path ($PSScriptRoot is empty
# when executed this way). It clones the repo to a fixed location and hands off
# to setup.ps1, which does the actual deployment — one codepath, not two.
$ErrorActionPreference = "Stop"

# Cold-machine fix: the old code hard-failed when PowerShell 7 or git was
# missing. Try winget first; only fall back to manual instructions when
# winget itself is unavailable or the install fails.
function Test-AirlockWingetAvailable {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Installing Airlock" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "PowerShell 7+ is required (current: $($PSVersionTable.PSVersion))." -ForegroundColor Yellow
    $psInstalled = $false
    if (Test-AirlockWingetAvailable) {
        Write-Host "Attempting to install PowerShell 7 via winget (one-time)..." -ForegroundColor Yellow
        & winget install --id Microsoft.PowerShell -e --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { $psInstalled = $true }
        else { Write-Host "winget install failed (exit $LASTEXITCODE)." -ForegroundColor Red }
    } else {
        Write-Host "winget is not available, cannot auto-install PowerShell 7." -ForegroundColor Yellow
    }
    if ($psInstalled) {
        # The running host cannot be upgraded in-process: exit and have the
        # user re-run this exact command from pwsh.
        Write-Host ""
        Write-Host "PowerShell 7 installed. Re-run this command from pwsh (not Windows PowerShell):" -ForegroundColor Green
        Write-Host "  irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex" -ForegroundColor White
        exit 0
    }
    Write-Host "Install PowerShell 7 from https://github.com/PowerShell/PowerShell, then re-run this command in pwsh." -ForegroundColor Gray
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $gitReady = $false
    if (Test-AirlockWingetAvailable) {
        Write-Host "git not found - installing via winget (one-time)..." -ForegroundColor Yellow
        & winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) {
            # Git's installer updates the machine PATH; refresh this process's copy.
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            if (Get-Command git -ErrorAction SilentlyContinue) { $gitReady = $true }
        } else {
            Write-Host "winget install failed (exit $LASTEXITCODE)." -ForegroundColor Red
        }
    } else {
        Write-Host "winget is not available, cannot auto-install git." -ForegroundColor Yellow
    }
    if (-not $gitReady) {
        Write-Host "ERROR: git is required but not found on PATH." -ForegroundColor Red
        Write-Host "Install it from https://git-scm.com/, then re-run this command." -ForegroundColor Gray
        exit 1
    }
    Write-Host "git installed successfully." -ForegroundColor Green
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
