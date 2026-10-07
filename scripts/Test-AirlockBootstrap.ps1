# Test-AirlockBootstrap.ps1 — installer decisions. No download, no Claude file write.
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "bootstrap.ps1")

$failures = 0
function Assert-Equal($name, $actual, $expected) {
    if ($actual -ne $expected) {
        Write-Host "FAIL: $name -> '$actual' expected '$expected'" -ForegroundColor Red
        $script:failures++
    } else {
        Write-Host "PASS: $name" -ForegroundColor Green
    }
}

$phase = Format-AirlockPhase -Name "hardware" -Detail "NVIDIA 16 GB, 14 GiB free"
if ($phase -notmatch '^phase  hardware\s+NVIDIA 16 GB, 14 GiB free$') {
    Write-Host "FAIL: phase shape -> '$phase'" -ForegroundColor Red
    $failures++
} else {
    Write-Host "PASS: phase shape" -ForegroundColor Green
}

$chat = Get-AirlockBootstrapPlan -StrategyAction "UseDefault" -ClaudeSafe $true
Assert-Equal "default runtime is chat" $chat.Runtime "chat"
Assert-Equal "default does not run the contract" $chat.Contract "skipped"
Assert-Equal "default writes no certificate" $chat.Certificate "none"

$nostart = Get-AirlockBootstrapPlan -StrategyAction "UseDefault" -NoStart -ClaudeSafe $true
Assert-Equal "NoStart does not start a runtime" $nostart.Runtime "skipped"

$need = Get-AirlockBootstrapPlan -StrategyAction "StepDown" -Coding -ClaudeSafe $true
Assert-Equal "coding without confirm does not download" $need.Ready "need-confirm"
Assert-Equal "coding without confirm skips contract" $need.Contract "skipped"

$run = Get-AirlockBootstrapPlan -StrategyAction "UseCandidate" -Coding -DownloadConfirmed -ClaudeSafe $true
Assert-Equal "confirmed coding uses llama-server" $run.Runtime "llama-server"
Assert-Equal "confirmed coding runs the contract" $run.Contract "run"

$refuse = Get-AirlockBootstrapPlan -StrategyAction "Refuse" -Coding -DownloadConfirmed -ClaudeSafe $true
Assert-Equal "refuse does not certify" $refuse.Certificate "none"
Assert-Equal "refuse falls back to chat" $refuse.Ready "chat-only"

$blocked = Get-AirlockBootstrapPlan -StrategyAction "UseDefault" -ClaudeSafe $false
Assert-Equal "poisoned claude stops the runtime" $blocked.Runtime "stop"

$clean = Test-AirlockClaudeSubscriptionSafe -EnvBlock $null -UserBaseUrl $null -UserAuthToken $null -UserApiKey $null
Assert-Equal "missing settings are safe" $clean.Safe $true

$api = [pscustomobject]@{ ANTHROPIC_BASE_URL = "https://api.anthropic.com" }
$official = Test-AirlockClaudeSubscriptionSafe -EnvBlock $api -UserBaseUrl $null -UserAuthToken $null -UserApiKey $null
Assert-Equal "api.anthropic.com alone is safe" $official.Safe $true

$local = [pscustomobject]@{ ANTHROPIC_BASE_URL = "http://127.0.0.1:12345"; ANTHROPIC_AUTH_TOKEN = "ollama" }
$hijack = Test-AirlockClaudeSubscriptionSafe -EnvBlock $local -UserBaseUrl $null -UserAuthToken $null -UserApiKey $null
Assert-Equal "loopback settings are not safe" $hijack.Safe $false

$empty = [pscustomobject]@{ ANTHROPIC_AUTH_TOKEN = "" }
$blank = Test-AirlockClaudeSubscriptionSafe -EnvBlock $empty -UserBaseUrl $null -UserAuthToken $null -UserApiKey $null
Assert-Equal "empty auth token is not safe" $blank.Safe $false

$user = Test-AirlockClaudeSubscriptionSafe -EnvBlock $null -UserBaseUrl "http://localhost:12345" -UserAuthToken $null -UserApiKey $null
Assert-Equal "user-scope localhost is not safe" $user.Safe $false

if ($failures -gt 0) { exit 1 }
Write-Host ""
Write-Host "All bootstrap checks passed" -ForegroundColor Green
