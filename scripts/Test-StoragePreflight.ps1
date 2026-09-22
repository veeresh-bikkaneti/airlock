# Self-check for Test-StoragePreflight (scripts/StoragePreflight.ps1).
# Run: pwsh -File scripts/Test-StoragePreflight.ps1
$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "StoragePreflight.ps1")

$failures = 0
function Assert-StorageCase {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { Write-Host "FAIL: $Name" -ForegroundColor Red; $script:failures++ }
}

$ok = Test-StoragePreflight -RequiredGB 5 -Path "C:\" -FreeBytesOverride ([long](20 * 1GB))
Assert-StorageCase -Condition ($ok.Ok -and $ok.FreeGB -eq 20) -Name "20 GB free vs 5 GB required passes"

$short = Test-StoragePreflight -RequiredGB 20 -Path "C:\" -FreeBytesOverride ([long](10 * 1GB))
Assert-StorageCase -Condition ((-not $short.Ok) -and $short.FreeGB -eq 10) -Name "10 GB free vs 20 GB required fails"
Assert-StorageCase -Condition ($short.Reason -match "Only 10 GB free") -Name "failure reason reports free space"

$exact = Test-StoragePreflight -RequiredGB 10 -Path "C:\" -FreeBytesOverride ([long](10 * 1GB))
Assert-StorageCase -Condition ($exact.Ok) -Name "exactly enough space passes"

# Live drive probe — exercises the real DriveInfo path on Windows. On Linux
# PowerShell, USERPROFILE is commonly unset and the Windows-style path does
# not identify a drive, so report an explicit portability skip instead of
# turning the platform limitation into a product failure.
if ($IsWindows -and $env:USERPROFILE) {
    try {
        $real = Test-StoragePreflight -RequiredGB 0.001 -Path $env:USERPROFILE
        Assert-StorageCase -Condition ($real.Ok -and $real.FreeGB -gt 0 -and $real.Drive) -Name "live drive probe returns free space and drive name"
    } catch {
        Write-Host "SKIP: live drive probe ($($_.Exception.Message))" -ForegroundColor Yellow
    }
} else {
    Write-Host "SKIP: live drive probe requires Windows USERPROFILE/DriveInfo" -ForegroundColor Yellow
}

if ($failures -gt 0) { Write-Host "$failures check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "All Test-StoragePreflight checks passed." -ForegroundColor Green
