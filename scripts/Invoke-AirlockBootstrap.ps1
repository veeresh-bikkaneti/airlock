# Invoke-AirlockBootstrap.ps1 — finish install in THIS window.
# Prints one phase line per step. Does not write ~/.claude/settings.json
# and does not set ANTHROPIC_* at User scope.
# Chat starts unless -NoStart or -Coding. Coding downloads only with
# -DownloadConfirmed, then runs the live Pi contract.
param(
    [switch]$Coding,
    [switch]$DownloadConfirmed,
    [switch]$NoStart,
    [string]$ScriptsRoot,
    [string]$PlatformDir = "$env:USERPROFILE\.ai-platform"
)

$ErrorActionPreference = "Stop"
if (-not $ScriptsRoot) { $ScriptsRoot = $PSScriptRoot }

. (Join-Path $ScriptsRoot "bootstrap.ps1")
. (Join-Path $ScriptsRoot "agent-profile-helpers.ps1")
. (Join-Path $ScriptsRoot "Get-HuggingFaceGguf.ps1")
. (Join-Path $ScriptsRoot "profile-helpers.ps1")

function Write-AirlockPhase {
    param([string]$Name, [string]$Detail)
    Write-Host (Format-AirlockPhase -Name $Name -Detail $Detail)
}

Write-AirlockPhase "deploy" "scripts at $PlatformDir"
Write-AirlockPhase "profile" "ai-start and ai-stop are live in this window"

$settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
$envBlock = $null
if (Test-Path $settingsPath) {
    try { $envBlock = (Get-Content $settingsPath -Raw | ConvertFrom-Json).env } catch { $envBlock = $null }
}
$userBase = $null; $userToken = $null; $userKey = $null
try {
    $userBase = [Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL', 'User')
    $userToken = [Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'User')
    $userKey = [Environment]::GetEnvironmentVariable('ANTHROPIC_API_KEY', 'User')
} catch { }

$claude = Test-AirlockClaudeSubscriptionSafe -EnvBlock $envBlock -UserBaseUrl $userBase -UserAuthToken $userToken -UserApiKey $userKey
Write-AirlockPhase "claude" $claude.Reason

$inventory = @(Get-AirlockNvidiaGpuList)
$freeRam = Get-AirlockFreeRamGiB
$pool = Resolve-AirlockGpuPool -Gpus $inventory -FreeRamGb $freeRam
if ($pool.UseRam) {
    $strategy = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb $null -FreeVramGiB $null -FreeRamGb $pool.FreeRamGb -Vendor ''
    $hardwareDetail = if ($null -eq $freeRam) { 'no discrete GPU, RAM unmeasured' } else { "no discrete GPU, $freeRam GiB RAM free" }
} else {
    $chosen = $pool.Chosen
    $amdNote = if ($pool.AmdNote) { [string]$pool.AmdNote } else { '' }
    $strategy = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb $chosen.TotalGiB -FreeVramGiB $chosen.FreeGiB -FreeRamGb $pool.FreeRamGb -Vendor $chosen.Vendor -AmdNote $amdNote
    $hardwareDetail = "$($chosen.Vendor) $($chosen.Name), $([math]::Round([double]$chosen.TotalGiB, 1)) GB, $([math]::Round([double]$chosen.FreeGiB, 1)) GiB free"
}
Write-AirlockPhase "hardware" $hardwareDetail
Write-AirlockPhase "pick" $strategy.Reason
if (-not $NoStart) {
    Save-AirlockHardwareDoctor -PlatformDir $PlatformDir -Text $strategy.Reason
}

$plan = Get-AirlockBootstrapPlan -StrategyAction $strategy.Action -Coding:$Coding -DownloadConfirmed:$DownloadConfirmed -NoStart:$NoStart -ClaudeSafe $claude.Safe

if ($plan.Ready -eq 'blocked') {
    Write-AirlockPhase "runtime" "not started"
    Write-AirlockPhase "contract" "skipped"
    Write-AirlockPhase "certificate" "none"
    Write-AirlockPhase "ready" "blocked until ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN are removed from $settingsPath and User env. Do not put them back."
    exit 1
}

if ($plan.Ready -eq 'need-confirm') {
    Write-AirlockPhase "runtime" "not started"
    Write-AirlockPhase "contract" "skipped"
    Write-AirlockPhase "certificate" "none"
    Write-AirlockPhase "ready" "coding needs a download. Re-run: `$env:AIRLOCK_CODING='1'; `$env:AIRLOCK_DOWNLOAD_CONFIRMED='1'; irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex"
    exit 0
}

if ($plan.Ready -eq 'chat-only') {
    Write-AirlockPhase "refuse" $strategy.Reason
}

if ($plan.Runtime -eq 'skipped') {
    Write-AirlockPhase "runtime" "not started"
    Write-AirlockPhase "contract" "skipped"
    Write-AirlockPhase "certificate" "none"
    Write-AirlockPhase "ready" "deployed. Next: ai-start -Backend ollama"
    exit 0
}

if ($plan.Runtime -eq 'chat') {
    Write-AirlockPhase "runtime" "chat, ollama, port 12345"
    & (Join-Path $ScriptsRoot "Start-AI.ps1") -Backend ollama
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-AirlockPhase "contract" "skipped"
        Write-AirlockPhase "certificate" "none"
        Write-AirlockPhase "ready" "chat failed (exit $LASTEXITCODE). Subscription was not modified."
        exit $LASTEXITCODE
    }
    Write-AirlockPhase "contract" "skipped (chat is not a coding proof)"
    Write-AirlockPhase "certificate" "none"
    Write-AirlockPhase "ready" "chat. Coding is separate: set AIRLOCK_CODING=1 and AIRLOCK_DOWNLOAD_CONFIRMED=1 and re-run install.ps1"
    exit 0
}

Write-AirlockPhase "runtime" "llama-server, one process, download confirmed"
& (Join-Path $ScriptsRoot "Start-AgentSession.ps1") -Harness pi-worker -DownloadConfirmed
$code = $LASTEXITCODE
if ($code -eq 0) {
    Write-AirlockPhase "contract" "Pi finished with exit 0"
    Write-AirlockPhase "certificate" "see $PlatformDir\state\active-agent.json — only if that file was written by this run"
    Write-AirlockPhase "ready" "coding"
    exit 0
}
Write-AirlockPhase "contract" "failed (exit $code)"
Write-AirlockPhase "certificate" "none"
Write-AirlockPhase "ready" "not coding-ready on this PC"
exit $code
