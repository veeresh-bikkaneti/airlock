# Invoke-CommitReview.ps1 – Pre‑commit security gate for AI‑assisted repos
# ------------------------------------------------------------
# What it does:
#   * Reads the commit‑policy JSON (list of patterns to block or require approval)
#   * Looks at the files staged for `git commit`
#   * Categorises each file as:
#       - BLOCKED   – will be unstaged automatically (e.g., API keys, passwords)
#       - NEEDS‑APPROVAL – prompts the user before committing
#       - AUTO‑APPROVED – safe to commit
#   * Provides a short interactive UI and finally runs `git commit` with a message.
# ------------------------------------------------------------
# Why you need it:
#   * Prevents accidental leakage of secrets from AI‑assisted development.
#   * Enforces organisation‑wide commit policies (PII, credentials, etc.).
#   * Works automatically – just replace `git commit` with `Invoke-CommitReview.ps1`.
# ------------------------------------------------------------
# Usage:
#   .\scripts\Invoke-CommitReview.ps1   # Run from the repository root
# ------------------------------------------------------------
# Note: The script is deliberately lightweight – it only relies on PowerShell and Git.
# ------------------------------------------------------------
# BEGIN SCRIPT
# Invoke-CommitReview.ps1

# Usage: & "$env:USERPROFILE\.ai-platform\scripts\Invoke-CommitReview.ps1"
# Run this INSTEAD of git commit in AI-assisted repos

# ------------------------------------------------------------
# Load the commit‑policy JSON which defines what patterns are forbidden or need approval.
# ------------------------------------------------------------
# Path to the JSON file that defines which files are forbidden or need manual approval before committing.
$POLICY_FILE = "$env:USERPROFILE\.ai-platform\config\policies\commit-policy.json"
if (-not (Test-Path $POLICY_FILE)) {
    Write-Host "No commit policy found at $POLICY_FILE" -ForegroundColor Yellow
    Write-Host "Run: git commit -m '...' directly" -ForegroundColor Gray
    exit 0
}
$policy = Get-Content $POLICY_FILE | ConvertFrom-Json

# ------------------------------------------------------------
# Determine which files are already staged for commit ("git add"ed).
# ------------------------------------------------------------
# Get the list of files that have been staged with 'git add' and are ready to be committed.
$staged = git diff --cached --name-only 2>$null
if (-not $staged) {
    Write-Host "Nothing staged. Run: git add <files>" -ForegroundColor Yellow
    exit 0
}

$blocked  = @()
$needsOK  = @()
$autoOK   = @()

# Classify each staged file according to the policy: always block, needs approval, or auto‑approved.
foreach ($file in $staged) {
    $isBlocked = $false
    $needsApproval = $false

    foreach ($pat in $policy.alwaysBlockPatterns) {
        if ($file -like $pat) { $isBlocked = $true; break }
    }
    if ($isBlocked) { $blocked += $file; continue }

    foreach ($pat in $policy.requireApprovalPatterns) {
        if ($file -like $pat) { $needsApproval = $true; break }
    }
    if ($needsApproval) { $needsOK += $file; continue }

    $autoOK += $file
}

Write-Host ""
Write-Host "AI Commit Review" -ForegroundColor Cyan
Write-Host "-----------------" -ForegroundColor DarkCyan

# Any files matching the always‑block patterns are automatically unstaged to prevent accidental leaks.
if ($blocked.Count -gt 0) {
    Write-Host ""
    Write-Host "BLOCKED - will be unstaged:" -ForegroundColor Red
    $blocked | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    $blocked | ForEach-Object { git restore --staged $_ 2>$null }
    Write-Host "These files were unstaged. Add them to .gitignore." -ForegroundColor Yellow
}

# Files that require explicit user approval are presented for a yes/no decision.
if ($needsOK.Count -gt 0) {
    Write-Host ""
    Write-Host "NEEDS APPROVAL:" -ForegroundColor Yellow
    $needsOK | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host ""
    $choice = Read-Host "Commit these too? [Y]es / [N]o (unstage)"
    if ($choice -notmatch "^[Yy]") {
        $needsOK | ForEach-Object { git restore --staged $_ 2>$null }
        Write-Host "Unstaged. Only auto-approved files remain." -ForegroundColor Cyan
        $needsOK = @()
    }
}

# Files that are safe to commit are listed for information.
if ($autoOK.Count -gt 0) {
    Write-Host ""
    Write-Host "AUTO-APPROVED:" -ForegroundColor Green
    $autoOK | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
}

# After handling blocked and approval files, see if any files are still staged for commit.
$remaining = git diff --cached --name-only 2>$null
if (-not $remaining) {
    Write-Host ""
    Write-Host "Nothing left to commit after review." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
# Prompt the user to enter a commit message for the final git commit.
$msg = Read-Host "Commit message"
if ($msg) {
    # Perform the actual git commit with the provided message.
    git commit -m $msg
    Write-Host ""
    Write-Host "Committed: $msg" -ForegroundColor Green
} else {
    Write-Host "Aborted - no message provided." -ForegroundColor Yellow
}