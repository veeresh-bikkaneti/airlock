# setup.ps1 — deploy the local AI platform scripts/config to ~/.ai-platform
# Usage: .\setup.ps1 [-Force]
#   -Force   overwrite files that already exist at the destination (config templates are
#            skipped by default so it never clobbers keys you've already filled in)
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlatformDir = "$env:USERPROFILE\.ai-platform"

Write-Host ""
Write-Host "Deploying local AI platform to $PlatformDir" -ForegroundColor Cyan

foreach ($dir in @($PlatformDir, "$PlatformDir\scripts", "$PlatformDir\config", "$PlatformDir\config\policies", "$PlatformDir\logs", "$PlatformDir\state")) {
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

# Scripts: always overwrite — repo is the source of truth for these.
Copy-Item "$RepoDir\scripts\*.ps1" "$PlatformDir\scripts\" -Force
Write-Host "  Scripts deployed" -ForegroundColor Green

# Memory service (opt-in): app source always overwritten, repo is the source of truth.
# The venv is created on first 'ai-memory-start', not here, so setup stays fast/offline.
if (Test-Path "$RepoDir\memory-service") {
    New-Item -Path "$PlatformDir\memory-service\app" -ItemType Directory -Force | Out-Null
    Copy-Item "$RepoDir\memory-service\app\*" "$PlatformDir\memory-service\app\" -Recurse -Force
    Copy-Item "$RepoDir\memory-service\requirements.txt" "$PlatformDir\memory-service\requirements.txt" -Force
    Write-Host "  Memory service deployed (opt-in — run ai-memory-start to use it)" -ForegroundColor Green
}

# Config: copy templates without clobbering anything the user has already filled in,
# unless -Force is passed. models.json and policy files are not secrets, always refresh those.
Copy-Item "$RepoDir\config\models.json" "$PlatformDir\config\models.json" -Force
Copy-Item "$RepoDir\config\policies\*.json" "$PlatformDir\config\policies\" -Force

Get-ChildItem "$RepoDir\config" -Filter "*.template" | ForEach-Object {
    $dest = Join-Path "$PlatformDir\config" $_.Name
    if ((Test-Path $dest) -and -not $Force) {
        Write-Host "  Skipped $($_.Name) (already exists, use -Force to overwrite)" -ForegroundColor DarkGray
    } else {
        Copy-Item $_.FullName $dest -Force
    }
}
Write-Host "  Config deployed" -ForegroundColor Green

# Wire profile-helpers.ps1 into the PowerShell profile so ai-start/ai-stop/etc. work in any new terminal.
if (-not (Test-Path $PROFILE)) {
    New-Item -Path $PROFILE -ItemType File -Force | Out-Null
}
$dotSourceLine = '. "$env:USERPROFILE\.ai-platform\scripts\profile-helpers.ps1"'
$profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if (-not $profileContent) { $profileContent = "" }
if (-not $profileContent.Contains($dotSourceLine)) {
    Add-Content -Path $PROFILE -Value "`n$dotSourceLine"
    Write-Host "  Added profile-helpers.ps1 to your PowerShell profile ($PROFILE)" -ForegroundColor Green
} else {
    Write-Host "  PowerShell profile already wired up" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Done. Open a new PowerShell terminal (or run '. `$PROFILE') and try 'ai-start'." -ForegroundColor Cyan
Write-Host "To add cloud fallback keys, run: ai-auth-set <provider> <api-key>  (e.g. ai-auth-set openrouter sk-or-...)" -ForegroundColor Gray
Write-Host ""
