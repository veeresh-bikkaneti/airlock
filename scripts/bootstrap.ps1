# bootstrap.ps1 — pure decisions for the one-command installer.
# No process start, no download, no settings write. Invoke-AirlockBootstrap.ps1
# does the I/O. Tests call these functions directly.

function Format-AirlockPhase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detail
    )
    return "phase  $($Name.PadRight(12)) $Detail"
}

# What the installer is allowed to do after it has inspected the machine.
# Coding is opt-in and still requires -DownloadConfirmed: the GGUF is ~13 GB
# and the certificate is a live Pi run, not a side effect of copying files.
# Chat is the default start. -NoStart prints the command and starts nothing.
function Get-AirlockBootstrapPlan {
    param(
        [Parameter(Mandatory)][string]$StrategyAction,
        [switch]$Coding,
        [switch]$DownloadConfirmed,
        [switch]$NoStart,
        [Parameter(Mandatory)][bool]$ClaudeSafe
    )
    if (-not $ClaudeSafe) {
        return [pscustomobject]@{
            Runtime = 'stop'; Contract = 'skipped'; Certificate = 'none'; Ready = 'blocked'
        }
    }
    if ($StrategyAction -eq 'Refuse' -and $Coding) {
        $runtime = if ($NoStart) { 'skipped' } else { 'chat' }
        return [pscustomobject]@{
            Runtime = $runtime; Contract = 'skipped'; Certificate = 'none'; Ready = 'chat-only'
        }
    }
    if ($Coding -and -not $DownloadConfirmed) {
        return [pscustomobject]@{
            Runtime = 'skipped'; Contract = 'skipped'; Certificate = 'none'; Ready = 'need-confirm'
        }
    }
    if ($Coding) {
        return [pscustomobject]@{
            Runtime = 'llama-server'; Contract = 'run'; Certificate = 'on-pass'; Ready = 'coding'
        }
    }
    if ($NoStart) {
        return [pscustomobject]@{
            Runtime = 'skipped'; Contract = 'skipped'; Certificate = 'none'; Ready = 'chat-command'
        }
    }
    return [pscustomobject]@{
        Runtime = 'chat'; Contract = 'skipped'; Certificate = 'none'; Ready = 'chat'
    }
}

# A settings env block or a User-scope variable wins over a Claude Pro login.
# Loopback, an empty token, or the "ollama" placeholder is the break.
# A normal https://api.anthropic.com base URL with no token is not.
function Test-AirlockClaudeSubscriptionSafe {
    param(
        $EnvBlock,
        [string]$UserBaseUrl,
        [string]$UserAuthToken,
        [string]$UserApiKey
    )
    $reasons = @()
    $names = @()
    if ($EnvBlock) { $names = @($EnvBlock.PSObject.Properties.Name) }

    $base = $null
    $token = $null
    $apiKey = $null
    if ($names -contains 'ANTHROPIC_BASE_URL') { $base = [string]$EnvBlock.ANTHROPIC_BASE_URL }
    if ($names -contains 'ANTHROPIC_AUTH_TOKEN') { $token = [string]$EnvBlock.ANTHROPIC_AUTH_TOKEN }
    if ($names -contains 'ANTHROPIC_API_KEY') { $apiKey = [string]$EnvBlock.ANTHROPIC_API_KEY }

    foreach ($pair in @(
            @{ Where = 'settings.json'; Base = $base; Token = $token; Key = $apiKey },
            @{ Where = 'User env'; Base = $UserBaseUrl; Token = $UserAuthToken; Key = $UserApiKey }
        )) {
        if ($pair.Base -match '127\.0\.0\.1|localhost') {
            $reasons += "$($pair.Where) ANTHROPIC_BASE_URL points at this PC ($($pair.Base))."
        }
        if ($null -ne $pair.Token -and $pair.Token -ne '' -and $pair.Where -eq 'User env' -and $pair.Token -eq 'ollama') {
            $reasons += "$($pair.Where) ANTHROPIC_AUTH_TOKEN is the ollama placeholder."
        }
        if ($pair.Where -eq 'settings.json' -and ($names -contains 'ANTHROPIC_AUTH_TOKEN') -and ($token -eq '' -or $token -eq 'ollama')) {
            $reasons += "settings.json ANTHROPIC_AUTH_TOKEN is empty or 'ollama'. That overrides the Pro login."
        }
        if ($pair.Key -eq 'ollama') {
            $reasons += "$($pair.Where) ANTHROPIC_API_KEY is the ollama placeholder."
        }
    }

    if ($reasons.Count -eq 0) {
        return [pscustomobject]@{ Safe = $true; Reason = 'subscription untouched' }
    }
    return [pscustomobject]@{ Safe = $false; Reason = ($reasons -join ' ') }
}
