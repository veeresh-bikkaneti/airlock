# grok-session-end.ps1 — write the same canonical SESSION_STATE block the
# Claude Code writer already uses. Git facts come only from `git -C $RepoPath`.
# No network. Does not call that Claude writer and does not launch a Grok TUI.
# A hard limit that kills Grok before this script runs is not captured.
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [string]$TurnsJson
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'session-resume.ps1')

if (-not (Test-Path -LiteralPath $RepoPath)) {
    throw "RepoPath not found: $RepoPath"
}

function Get-AirlockGitStdout {
    param([Parameter(Mandatory)][string[]]$GitArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $RepoPath @GitArgs
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) {
        throw "git -C $RepoPath $($GitArgs -join ' ') failed (exit $code)"
    }
    return @($output)
}

$branch = ([string]@(Get-AirlockGitStdout -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD'))[0]).Trim()
$lastCommit = ([string]@(Get-AirlockGitStdout -GitArgs @('log', '-1', '--format=%h %s'))[0]).Trim()
$statusLines = @(Get-AirlockGitStdout -GitArgs @('status', '--porcelain', '--untracked-files=all'))

$changed = New-Object System.Collections.Generic.List[string]
foreach ($line in $statusLines) {
    $text = [string]$line
    if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -lt 4) { continue }
    $rest = $text.Substring(3).Trim()
    if ($rest -match ' -> ') {
        $rest = ($rest -split ' -> ')[-1].Trim()
    }
    if ($rest.StartsWith('"') -and $rest.EndsWith('"') -and $rest.Length -ge 2) {
        $rest = $rest.Substring(1, $rest.Length - 2)
    }
    if ($rest) { [void]$changed.Add($rest) }
}

if ($PSBoundParameters.ContainsKey('TurnsJson') -and -not [string]::IsNullOrWhiteSpace($TurnsJson)) {
    $parsed = $TurnsJson | ConvertFrom-Json
    $turns = @($parsed)
} else {
    $turns = @('Grok session ended without a transcript; git state only.')
}

Write-AirlockSessionState -RepoPath $RepoPath -SessionId 'grok' -Branch $branch `
    -LastCommit $lastCommit -ChangedFiles ([string[]]@($changed)) -Turns $turns
