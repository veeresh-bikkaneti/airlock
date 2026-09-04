# Self-check for AIR-016 `ai-agent-start` (spec T1-T8).
# No GPU, no llama-server, no HuggingFace network.
# Run: pwsh -File scripts/Test-AgentStart.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing AIR-016 ai-agent-start..." -ForegroundColor Cyan

# --- T1: profile-helpers.ps1 defines ai-agent-start ---
$helpersPath = Join-Path $ScriptDir "profile-helpers.ps1"
$helpersText = Get-Content $helpersPath -Raw
Assert-True ($helpersText -match 'function global:ai-agent-start') "T1: profile-helpers.ps1 defines function global:ai-agent-start"
Assert-True ($helpersText -match 'llamacpp-qwen38-ud-q3-k-xl') "T1: ai-agent-start defaults to the Unsloth profile id"
Assert-True ($helpersText -match 'pi-worker') "T1: ai-agent-start defaults to harness pi-worker"

# --- T2-T4: GGUF mapper + skip/mismatch ---
$ggufHelper = Join-Path $ScriptDir "Get-HuggingFaceGguf.ps1"
Assert-True (Test-Path $ggufHelper) "T2: scripts/Get-HuggingFaceGguf.ps1 exists"
if (Test-Path $ggufHelper) {
    $ggufText = Get-Content $ggufHelper -Raw
    Assert-True ($ggufText -notmatch '& ollama create') "G3: huggingface-gguf helper never calls ollama create"
    . $ggufHelper
    $fileName = ConvertTo-AirlockGgufFileName -ModelRef 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL'
    Assert-True ($fileName -eq 'Qwen3.8-27B-UD-Q3_K_XL.gguf') "T2: mapper unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL -> Qwen3.8-27B-UD-Q3_K_XL.gguf"

    $repo = ConvertTo-AirlockHfRepo -ModelRef 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL'
    Assert-True ($repo -eq 'unsloth/Qwen3.8-27B-GGUF') "T2: HF repo is unsloth/Qwen3.8-27B-GGUF"

    $evidence = [long]13146393504
    Assert-True (Test-AirlockGgufEvidenceMatch -ByteLength $evidence) "T3: exact evidence byte size matches"
    Assert-True (-not (Test-AirlockGgufEvidenceMatch -ByteLength 1)) "T4: a different size is not the evidence artifact"

    $skip = Resolve-AirlockGgufAcquisition -DestExists $true -DestLength $evidence -UserConfirmed $false
    Assert-True ($skip.Action -eq 'SkipDownload') "T3: existing file with size 13146393504 -> SkipDownload"
    Assert-True ($skip.MatchedEvidenceBytes -eq $true) "T3: skip records matchedEvidenceBytes=true"
    Assert-True ($skip.ForceVerify -eq $false) "T3: evidence-bound artifact does not force a live contract"

    $mismatch = Resolve-AirlockGgufAcquisition -DestExists $true -DestLength 42 -UserConfirmed $false
    Assert-True ($mismatch.Action -eq 'UseExistingMismatch') "T4: existing file with other size -> UseExistingMismatch"
    Assert-True ($mismatch.MatchedEvidenceBytes -eq $false) "T4: mismatch does not inherit the 3/3"
    Assert-True ($mismatch.ForceVerify -eq $true) "T4: mismatch requires a live contract (ForceVerify)"

    $needYes = Resolve-AirlockGgufAcquisition -DestExists $false -DestLength 0 -UserConfirmed $false
    Assert-True ($needYes.Action -eq 'RequireConfirmation') "dest missing without confirmation -> RequireConfirmation (fail closed)"

    $download = Resolve-AirlockGgufAcquisition -DestExists $false -DestLength 0 -UserConfirmed $true
    Assert-True ($download.Action -eq 'Download') "dest missing with recorded yes -> Download"
} else {
    Assert-True $false "T2: ConvertTo-AirlockGgufFileName unavailable"
    Assert-True $false "T3: skip-download branch unavailable"
    Assert-True $false "T4: mismatch branch unavailable"
}

# --- T5: Start-LlamaCppRuntime default HealthTimeoutSec is 300 ---
$llamaPath = Join-Path $ScriptDir "runtime-adapters" "llamacpp.ps1"
. $llamaPath
$param = (Get-Command Start-LlamaCppRuntime).ScriptBlock.Ast.Body.ParamBlock.Parameters |
    Where-Object { $_.Name.VariablePath.UserPath -eq 'HealthTimeoutSec' } |
    Select-Object -First 1
$defaultTimeout = $null
if ($param -and $param.DefaultValue) { $defaultTimeout = [int]$param.DefaultValue.Value }
Assert-True ($defaultTimeout -eq 300) "T5: Start-LlamaCppRuntime default HealthTimeoutSec is 300 (got $defaultTimeout)"

# --- T6: hermes models.json lists the Unsloth id ---
$modelsPath = Join-Path $RepoRoot "hermes-container" "config" "models.json"
$models = Get-Content $modelsPath -Raw | ConvertFrom-Json
$ids = @($models.providers.'ollama-local'.models | ForEach-Object { $_.id })
Assert-True ($ids -contains 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL') "T6: hermes models.json lists unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL"

# --- T7: WhatIf Unsloth + pi-worker exits 0 and prints openai-direct ---
$sessionScript = Join-Path $ScriptDir "Start-AgentSession.ps1"
$cataloguePath = Join-Path $RepoRoot "config" "agent-profiles.json"
$whatIfDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-agent-start-whatif-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $whatIfDir -ItemType Directory -Force | Out-Null
try {
    $whatIfOut = & pwsh -NoProfile -File $sessionScript -Profile 'llamacpp-qwen38-ud-q3-k-xl' -Harness 'pi-worker' `
        -PlatformDir $whatIfDir -ProfileCataloguePath $cataloguePath -WhatIf 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "T7: Start-AgentSession -WhatIf -Profile Unsloth -Harness pi-worker exits 0"
    Assert-True ($whatIfOut -match 'openai-direct') "T7: WhatIf prints openai-direct"
    Assert-True (-not (Test-Path (Join-Path $whatIfDir "state" "active-agent.json"))) "T7: WhatIf never publishes a certificate"
} finally {
    Remove-Item -Path $whatIfDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- T8 / D7: Ollama coding certificate is refused unless a live pass this run ---
. (Join-Path $ScriptDir "agent-profile-helpers.ps1")
$cmdOllama = Get-Command Resolve-AirlockOllamaCodingCertificate -ErrorAction SilentlyContinue
Assert-True ([bool]$cmdOllama) "T8: Resolve-AirlockOllamaCodingCertificate exists"
if ($cmdOllama) {
    $refused = Resolve-AirlockOllamaCodingCertificate -LiveContractPassedThisRun $false
    Assert-True (-not $refused.Allow) "T8: Ollama path does not publish a certificate without a live pass this run"
    $allowed = Resolve-AirlockOllamaCodingCertificate -LiveContractPassedThisRun $true
    Assert-True $allowed.Allow "T8: a live contract this run is the only Ollama coding exception"
}

# --- D4 G2: production Start-LlamaCppRuntime call, not only the error string ---
$sessionText = Get-Content $sessionScript -Raw
Assert-True ($sessionText -match 'Start-LlamaCppRuntime') "G2: Start-AgentSession mentions Start-LlamaCppRuntime"
Assert-True ($sessionText -notmatch 'is not automated in this pass') "G2: the manual-start error string is gone"
Assert-True ($sessionText -match 'Start-LlamaCppRuntime\s+-ModelPath') "G2: Start-AgentSession has a production Start-LlamaCppRuntime call"

# --- D9: VRAM start gate ---
$cmdVram = Get-Command Resolve-AirlockVramStartGate -ErrorAction SilentlyContinue
Assert-True ([bool]$cmdVram) "D9: Resolve-AirlockVramStartGate exists"
if ($cmdVram) {
    $low = Resolve-AirlockVramStartGate -FreeVramGiB 8 -MinimumFreeVramGiB 14 -RequiresGpuLayersAll $true
    Assert-True (-not $low.Allowed) "D9: free VRAM below 14 GiB refuses to start"
    $ok = Resolve-AirlockVramStartGate -FreeVramGiB 16 -MinimumFreeVramGiB 14 -RequiresGpuLayersAll $true
    Assert-True $ok.Allowed "D9: free VRAM at/above 14 GiB is allowed"
    $thinkpadIdle = Resolve-AirlockVramStartGate -FreeVramGiB 15 -MinimumFreeVramGiB 14 -RequiresGpuLayersAll $true
    Assert-True $thinkpadIdle.Allowed "D9: ThinkPad P16 Gen 2 idle ~15 GiB free on RTX 5000 Ada passes the 14 GiB Unsloth floor"
    $thinkpadLoaded = Resolve-AirlockVramStartGate -FreeVramGiB ([double]2051 / 1024) -MinimumFreeVramGiB 14 -RequiresGpuLayersAll $true
    Assert-True (-not $thinkpadLoaded.Allowed) "D9: same GPU with Unsloth resident (~2.0 GiB free, ADR-013) refuses a second start"
    $missing = Resolve-AirlockVramStartGate -FreeVramGiB $null -MinimumFreeVramGiB 14 -RequiresGpuLayersAll $true
    Assert-True (-not $missing.Allowed) "D9: nvidia-smi missing + GPU layers all refuses to start"
}

# --- D1: ai-code / ai-switch / worker consume or invalidate the certificate ---
Assert-True ($helpersText -match 'Resolve-AirlockCertificateValidity') "D1: profile-helpers consumes Resolve-AirlockCertificateValidity"
Assert-True ($helpersText -match 'Clear-AirlockActiveAgentCertificate') "D1: ai-switch invalidates the certificate"
$workerText = Get-Content (Join-Path $ScriptDir "Start-AgentWorkerJob.ps1") -Raw
Assert-True ($workerText -match 'Resolve-AirlockCertificateValidity') "D1: Start-AgentWorkerJob refuses without an unexpired certificate"

# --- D6 helper: Clear-AirlockActiveAgentCertificate ---
. (Join-Path $ScriptDir "agent-state-helpers.ps1")
$cmdClear = Get-Command Clear-AirlockActiveAgentCertificate -ErrorAction SilentlyContinue
Assert-True ([bool]$cmdClear) "D1: Clear-AirlockActiveAgentCertificate exists"
if ($cmdClear) {
    $clearDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-clear-cert-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $clearDir -ItemType Directory -Force | Out-Null
    try {
        $cert = Join-Path $clearDir "active-agent.json"
        Set-Content -Path $cert -Value '{"schemaVersion":1}' -Encoding utf8
        Clear-AirlockActiveAgentCertificate -CertificatePath $cert
        Assert-True (-not (Test-Path $cert)) "D1: Clear-AirlockActiveAgentCertificate deletes the certificate file"
        Clear-AirlockActiveAgentCertificate -CertificatePath $cert
        Assert-True $true "D1: clearing a missing certificate is a no-op"
    } finally {
        Remove-Item -Path $clearDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures AIR-016 ai-agent-start check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All AIR-016 ai-agent-start checks passed" -ForegroundColor Green
exit 0
