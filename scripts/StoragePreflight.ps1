# StoragePreflight.ps1 — disk-space preflight for multi-GB model downloads.
# Cold-machine fix: the chat-door pull and the ~13 GB coding-door GGUF used
# to download blind; a nearly-full disk produced a failed download (or a
# stranded "pending" model) instead of a clear, early refuse.
# Test-StoragePreflight is pure — free space is injectable via
# -FreeBytesOverride — and is self-tested by scripts/Test-StoragePreflight.ps1
# (picked up automatically by CI's Test-*.ps1 sweep).

function Test-StoragePreflight {
    param(
        [Parameter(Mandatory)][double]$RequiredGB,
        [string]$Path = "$env:USERPROFILE",
        [Nullable[long]]$FreeBytesOverride = $null
    )
    $driveName = $null
    $freeBytes = $FreeBytesOverride
    if ($null -eq $freeBytes) {
        try {
            $full = [System.IO.Path]::GetFullPath($Path)
            $root = [System.IO.Path]::GetPathRoot($full)
            $drive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq $root } | Select-Object -First 1
            if (-not $drive) {
                return [pscustomobject]@{
                    Ok = $false; FreeGB = 0; RequiredGB = $RequiredGB; Drive = $root
                    Reason = "Could not determine the drive hosting '$Path'; refusing a multi-GB download blind."
                }
            }
            $driveName = $drive.Name
            $freeBytes = $drive.AvailableFreeSpace
        } catch {
            return [pscustomobject]@{
                Ok = $false; FreeGB = 0; RequiredGB = $RequiredGB; Drive = $driveName
                Reason = "Could not read free disk space: $($_.Exception.Message)"
            }
        }
    }
    $freeGB = [math]::Round($freeBytes / 1GB, 2)
    $needGB = [math]::Round($RequiredGB, 2)
    $driveLabel = if ($driveName) { " on $driveName" } else { "" }
    if ($freeGB -lt $RequiredGB) {
        return [pscustomobject]@{
            Ok = $false; FreeGB = $freeGB; RequiredGB = $RequiredGB; Drive = $driveName
            Reason = "Only $freeGB GB free$driveLabel; need $needGB GB. Free up disk space and retry — nothing was downloaded."
        }
    }
    return [pscustomobject]@{
        Ok = $true; FreeGB = $freeGB; RequiredGB = $RequiredGB; Drive = $driveName
        Reason = "$freeGB GB free$driveLabel; need $needGB GB."
    }
}
