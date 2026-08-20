# Reverses setup.ps1 / the irm|iex installer (AIR-H3). Removes:
#   - $env:USERPROFILE\.ai-platform (everything setup.ps1 deployed there)
#   - $env:USERPROFILE\.airlock-src (the installer's own source clone, AIR-H16)
#   - the profile-helpers.ps1 sourcing line setup.ps1 added to $PROFILE
#   - firewall rules this platform created (same "AI-Platform-*-Block-*" pattern Stop-AI.ps1
#     already uses to clean these up on ai-stop -CleanFirewall)
#
# Does NOT touch Ollama itself or any pulled model - those are the user's, installed and
# managed independently of this platform, and this uninstaller has no business deleting
# gigabytes of model weights as a side effect of removing a set of PowerShell scripts.
#
# The ai-doctor provenance check runs FIRST, before anything is deleted (AIR-H16 regression:
# it used to run after $PlatformDir was gone, so its own Test-Path guard silently skipped it
# on every real run - only -WhatIf testing ever saw it execute).
#
# Usage: pwsh -File scripts/Uninstall-AI.ps1 [-WhatIf]
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PlatformDir = "$env:USERPROFILE\.ai-platform",
    [string]$SrcDir      = "$env:USERPROFILE\.airlock-src"
)

$DotSourceLine = '. "$env:USERPROFILE\.ai-platform\scripts\profile-helpers.ps1"'

Write-Host "Airlock Uninstaller" -ForegroundColor Cyan
Write-Host "===================" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "This removes the platform's own install directory, profile hook, and firewall" -ForegroundColor Gray
Write-Host "rules only. Ollama itself and every pulled model are left alone." -ForegroundColor Gray
Write-Host ""

# --- 1. Provenance check (same reasoning as AIR-H1's ai-doctor) ---
# Must run before anything below is deleted: this sources profile-helpers.ps1 from next to
# this script, and step 2 removes $PlatformDir (which contains that file). Removing files on
# disk does not reach a process that already has a copy of ANTHROPIC_*/OPENAI_* in its own
# environment block - Windows hands each process a COPY at creation and never re-reads it.
# This shell (and this shell alone - there is no supported, non-admin way to read another
# running process's environment block) can be checked directly by reusing ai-doctor, which
# already classifies exactly this failure mode.
Write-Host "Checking this shell for a leftover platform redirect..." -ForegroundColor Cyan
$doctorSource = Join-Path $PSScriptRoot "profile-helpers.ps1"
if (Test-Path $doctorSource) {
    . $doctorSource *> $null
    ai-doctor
} else {
    Write-Host "  Could not find profile-helpers.ps1 next to this script to run ai-doctor's check." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "This uninstaller cannot see other already-open shells, editors, or agent CLIs." -ForegroundColor Yellow
Write-Host "Any of them that had ai-claude-on active still carry a frozen copy of these variables" -ForegroundColor Yellow
Write-Host "in their own environment block. Close every one of them, or sign out/reboot, to be sure." -ForegroundColor Yellow
Write-Host ""

# --- 2. Platform install directory ---
if (Test-Path $PlatformDir) {
    if ($PSCmdlet.ShouldProcess($PlatformDir, "Remove directory (recursive)")) {
        Remove-Item -Path $PlatformDir -Recurse -Force
        Write-Host "  Removed $PlatformDir" -ForegroundColor Green
    }
} else {
    Write-Host "  $PlatformDir does not exist - nothing to remove" -ForegroundColor Gray
}

# --- 3. Installer source clone (AIR-H16) ---
if (Test-Path $SrcDir) {
    if ($PSCmdlet.ShouldProcess($SrcDir, "Remove directory (recursive)")) {
        Remove-Item -Path $SrcDir -Recurse -Force
        Write-Host "  Removed $SrcDir" -ForegroundColor Green
    }
} else {
    Write-Host "  $SrcDir does not exist - nothing to remove" -ForegroundColor Gray
}

# --- 4. $PROFILE sourcing line ---
if (Test-Path $PROFILE) {
    $content = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains($DotSourceLine)) {
        if ($PSCmdlet.ShouldProcess($PROFILE, "Remove profile-helpers.ps1 sourcing line")) {
            $lines = $content -split "`r?`n" | Where-Object { $_.Trim() -ne $DotSourceLine.Trim() }
            Set-Content -Path $PROFILE -Value ($lines -join "`r`n")
            Write-Host "  Removed the profile-helpers.ps1 sourcing line from $PROFILE" -ForegroundColor Green
        }
    } else {
        Write-Host "  $PROFILE does not reference profile-helpers.ps1 - nothing to remove" -ForegroundColor Gray
    }
} else {
    Write-Host "  $PROFILE does not exist - nothing to remove" -ForegroundColor Gray
}

# --- 5. Firewall rules ---
# Same DisplayName pattern Stop-AI.ps1's -CleanFirewall path already matches
# ("AI-Platform-Ollama-Block-<port>", "AI-Platform-Memory-Block-<port>", etc).
$rules = Get-NetFirewallRule -DisplayName "AI-Platform-*-Block-*" -ErrorAction SilentlyContinue
if ($rules) {
    foreach ($rule in $rules) {
        if ($PSCmdlet.ShouldProcess($rule.DisplayName, "Remove firewall rule")) {
            try {
                Remove-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction Stop
                Write-Host "  Removed firewall rule: $($rule.DisplayName)" -ForegroundColor Green
            } catch {
                Write-Host "  Could not remove firewall rule '$($rule.DisplayName)' - needs admin? $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
} else {
    Write-Host "  No AI-Platform-*-Block-* firewall rules found - nothing to remove" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Ollama and all pulled models were left untouched." -ForegroundColor Cyan
Write-Host "Use Ollama's own uninstaller, and 'ollama rm <model>' per model, if you want those gone too." -ForegroundColor Gray
