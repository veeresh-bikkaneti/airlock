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
Assert-True ($helpersText -notmatch "Profile = 'llamacpp-qwen38-ud-q3-k-xl'") "T1: ai-agent-start does not hardcode the ThinkPad Q3 profile — empty -Profile sizes this PC"
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

    $iq3 = ConvertTo-AirlockGgufFileName -ModelRef 'unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS'
    Assert-True ($iq3 -eq 'Qwen3.8-27B-UD-IQ3_XXS.gguf') "ADR-018: mapper UD-IQ3_XXS -> Qwen3.8-27B-UD-IQ3_XXS.gguf"
    $q4 = ConvertTo-AirlockGgufFileName -ModelRef 'unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL'
    Assert-True ($q4 -eq 'Qwen3.8-27B-UD-Q4_K_XL.gguf') "ADR-018: mapper UD-Q4_K_XL -> Qwen3.8-27B-UD-Q4_K_XL.gguf"

    $ladder = Get-AirlockUnslothQuantLadder
    $q3row = $ladder | Where-Object { $_.Quant -eq 'UD-Q3_K_XL' } | Select-Object -First 1
    Assert-True ($q3row.CodingDefault -eq $true) "ADR-018: UD-Q3_K_XL is the only coding-default row"
    $defaults = @($ladder | Where-Object { $_.CodingDefault })
    Assert-True ($defaults.Count -eq 1) "ADR-018: exactly one coding-default quant"

    $adaIdle = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 16 -FreeVramGiB 15 -Vendor 'NVIDIA'
    Assert-True ($adaIdle.Action -eq 'UseDefault') "ADR-018: ThinkPad idle 15 GiB -> UseDefault"
    Assert-True ($adaIdle.Quant -eq 'UD-Q3_K_XL') "ADR-018: ThinkPad idle stays UD-Q3_K_XL"
    Assert-True ($adaIdle.InheritEvidence -eq $true) "ADR-018: Q3_K_XL may inherit the 3/3"
    Assert-True ($adaIdle.ContextTokens -eq 8192) "ADR-018: NVIDIA 16 GB full floor stays ctx 8192"

    $noVendor = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 16 -FreeVramGiB 15
    Assert-True ($noVendor.Action -eq 'UseCandidate') "empty vendor is UseCandidate even when the numbers match the ThinkPad"
    Assert-True ($noVendor.InheritEvidence -eq $false) "empty vendor does not inherit the 3/3"
    Assert-True ($noVendor.ContextTokens -eq 8192) "empty vendor full floor stays ctx 8192"

    $adaTight = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 16 -FreeVramGiB 13
    Assert-True ($adaTight.Action -eq 'StepDown') "ADR-018: 13 GiB free steps down"
    Assert-True ($adaTight.Quant -eq 'UD-IQ3_XXS') "ADR-018: 13 GiB free -> UD-IQ3_XXS"
    Assert-True ($adaTight.InheritEvidence -eq $false) "ADR-018: step-down never inherits the 3/3"

    $ada2bit = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 16 -FreeVramGiB 11.2
    Assert-True ($ada2bit.Quant -eq 'UD-Q2_K_XL') "ADR-018: ~11 GiB free -> UD-Q2_K_XL"

    $adaLow = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 16 -FreeVramGiB 8
    Assert-True ($adaLow.Action -eq 'Refuse') "ADR-018: 8 GiB VRAM with no RAM figure still refuses (no silent 1-bit)"

    $ramOff = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 16 -FreeVramGiB 8 -FreeRamGb 32
    Assert-True ($ramOff.Action -eq 'CpuOffload') "8 GiB VRAM + 32 GiB RAM -> RAM mmap, not refuse"
    Assert-True ($ramOff.Quant -eq 'UD-Q3_K_XL') "32 GiB RAM mmap uses the Q3 GGUF (same weights, CPU)"
    Assert-True ($ramOff.Offload -eq 'cpu') "RAM path is labeled cpu"
    Assert-True (-not $ramOff.InheritEvidence) "RAM mmap never inherits the GPU 3/3"

    $noGpuRam = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb $null -FreeVramGiB $null -FreeRamGb 24
    Assert-True ($noGpuRam.Action -eq 'CpuOffload') "no NVIDIA GPU + 24 GiB RAM still gets a coding mmap"
    Assert-True ($noGpuRam.Quant -eq 'UD-Q3_K_XL') "24 GiB RAM is enough for Q3 mmap"

    $tinyRam = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb $null -FreeVramGiB $null -FreeRamGb 6
    Assert-True ($tinyRam.Action -eq 'Refuse') "6 GiB RAM cannot mmap a Unsloth 27B GGUF"

    $card24 = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 24 -FreeVramGiB 22 -Vendor 'NVIDIA'
    Assert-True ($card24.Action -eq 'StepUp') "24 GB card steps up off the ThinkPad Q3 default"
    Assert-True ($card24.Quant -eq 'UD-Q4_K_XL') "22 GiB free picks UD-Q4_K_XL (17.6 GB), not Q3"
    Assert-True ($card24.InheritEvidence -eq $false) "step-up does not inherit the 16 GB Q3 3/3"
    Assert-True ($card24.Fit -eq 'Good') "17.6/22 is Good, not Perfect"
    Assert-True ($card24.Reason -notmatch 'RTX-class') "a 24 GB pick is not described as the RTX 5000 class"

    $card32 = Resolve-AirlockUnslothQuantForProfile -Name 'rtx-5090-32'
    Assert-True ($card32.Quant -eq 'UD-Q6_K_XL') "30 GiB free steps up to UD-Q6_K_XL"
    Assert-True ($card32.InheritEvidence -eq $false) "32 GB class does not inherit the ThinkPad certificate"

    $card48 = Resolve-AirlockUnslothQuantForProfile -Name 'rtx-a6000-48'
    Assert-True ($card48.Quant -eq 'UD-Q8_K_XL') "44 GiB free steps up to UD-Q8_K_XL"
    Assert-True ($card48.Offload -eq 'gpu-all') "a large NVIDIA card stays gpu-all"

    $adaNamed = Resolve-AirlockUnslothQuantForProfile -Name 'thinkpad-rtx-5000-ada-16'
    Assert-True ($adaNamed.Quant -eq 'UD-Q3_K_XL') "named ThinkPad profile stays UD-Q3_K_XL"
    Assert-True ($adaNamed.InheritEvidence -eq $true) "named 16 GB NVIDIA profile may inherit the evidence quant"
    Assert-True ($adaNamed.Fit -eq 'Marginal') "13.1 GB weights in 15 GiB free is Marginal, not Perfect"

    $amd = Resolve-AirlockUnslothQuantForProfile -Name 'rx-7800-xt-16'
    Assert-True ($amd.Quant -eq 'UD-Q3_K_XL') "16 GB AMD card still fits Q3"
    Assert-True ($amd.Action -eq 'UseCandidate') "AMD is not the NVIDIA evidence class"
    Assert-True ($amd.InheritEvidence -eq $false) "an AMD 16 GB card does not inherit the Ada 3/3"
    Assert-True ($amd.Reason -match 'AMD') "the reason names the vendor it measured"

    $full16 = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 16 -FreeVramGiB 16 -Vendor 'NVIDIA'
    Assert-True ($full16.Quant -eq 'UD-Q3_K_XL') "a full 16 GB card does not step up into UD-IQ4_XS (spills at 8k)"

    $cpuNamed = Resolve-AirlockUnslothQuantForProfile -Name 'cpu-32gb'
    Assert-True ($cpuNamed.Action -eq 'CpuOffload') "cpu-32gb profile is a RAM mmap"
    Assert-True ($cpuNamed.Fit -eq 'Good') "CPU fit is capped at Good even when RAM headroom looks Perfect"

    $missing = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb $null -FreeVramGiB $null
    Assert-True ($missing.Action -eq 'Refuse') "ADR-018: missing nvidia-smi AND missing RAM refuses a quant pick"

    $iq3At13 = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 16 -FreeVramGiB 13.0 -Vendor 'NVIDIA'
    Assert-True ($iq3At13.Quant -eq 'UD-IQ3_XXS') "13.0 GiB free on NVIDIA 16 GB steps down to UD-IQ3_XXS"
    Assert-True ($iq3At13.ContextTokens -eq 8192) "13.0 GiB free keeps UD-IQ3_XXS at ctx 8192"
    Assert-True ($iq3At13.InheritEvidence -eq $false) "13.0 GiB IQ3 does not inherit"

    # Q3 half floor is FileGb + (14 - FileGb) / 2 = 13.55. 13.6 clears that
    # and misses 14. NVIDIA 16 GB so a fail here is half-context, not empty vendor.
    $halfQ3 = Resolve-AirlockUnslothQuantStrategy -GpuTotalGb 16 -FreeVramGiB 13.6 -Vendor 'NVIDIA'
    Assert-True ($halfQ3.Quant -eq 'UD-Q3_K_XL') "13.6 GiB free stays on UD-Q3_K_XL"
    Assert-True ($halfQ3.ContextTokens -eq 4096) "13.6 GiB free is half context 4096"
    Assert-True ($halfQ3.InheritEvidence -eq $false) "half-context UD-Q3_K_XL does not inherit"
    Assert-True ($halfQ3.Action -eq 'UseCandidate') "half-context Q3 is UseCandidate"

    $pool = Resolve-AirlockGpuPool -Gpus @(
        [pscustomobject]@{ Name = 'smaller-gpu'; Vendor = 'NVIDIA'; TotalGiB = 8; FreeGiB = 8; Unified = $false }
        [pscustomobject]@{ Name = 'RTX-4090-24'; Vendor = 'NVIDIA'; TotalGiB = 24; FreeGiB = 22; Unified = $false }
    ) -FreeRamGb 64
    Assert-True ($pool.Chosen.FreeGiB -eq 22) "GPU pool picks the 22 GiB free GPU only"
    Assert-True ($pool.Reason -match 'not added') "GPU pool reason says other GPUs were not added"
    Assert-True ($pool.Reason -match 'smaller-gpu') "GPU pool reason names the smaller GPU"
    Assert-True ($pool.Reason -notmatch '30') "GPU pool does not report a summed pool"
    Assert-True (-not ($pool.PSObject.Properties.Name -contains 'SummedFreeGiB')) "GPU pool has no summed-free field"

    $unified = Resolve-AirlockGpuPool -Gpus @(
        [pscustomobject]@{ Name = 'unified-gpu'; Vendor = 'Apple'; TotalGiB = 16; FreeGiB = 12; Unified = $true }
    ) -FreeRamGb 24
    Assert-True ($unified.UseRam -eq $true) "a unified-memory device alone uses RAM"
    Assert-True ($null -eq $unified.Chosen) "a unified-memory device is not a chosen VRAM GPU"
    Assert-True ($unified.Reason -match 'unified memory is not VRAM') "unified memory is not VRAM"

    $amdPool = Resolve-AirlockGpuPool -Gpus @(
        [pscustomobject]@{ Name = 'RX 7800 XT'; Vendor = 'AMD'; TotalGiB = 16; FreeGiB = 15; Unified = $false }
    ) -FreeRamGb 32
    Assert-True ($amdPool.AmdNote -match 'Vulkan') "AMD note mentions Vulkan"
    Assert-True ($amdPool.AmdNote -match 'not CUDA') "AMD note says not CUDA"
    Assert-True ($amdPool.AmdNote -match 'live Pi') "AMD note requires live Pi"
    $amdProfile = Resolve-AirlockUnslothQuantForProfile -Name 'rx-7800-xt-16'
    Assert-True ($amdProfile.InheritEvidence -eq $false) "rx-7800-xt-16 strategy still does not inherit"
    $amdDoc = Format-AirlockHardwareDoctor -Pool $amdPool -Pick $amdProfile -SpeedLine 'speed unknown'
    Assert-True ($amdDoc.Contains([string]$amdPool.AmdNote)) "doctor includes the AMD note sentence"

    Assert-True ($null -eq (Get-AirlockSpeedEstimate -FileGb 13.1 -BandwidthGiBps $null -Offload 'gpu-all')) "missing bandwidth returns null"
    Assert-True ($null -eq (Get-AirlockSpeedEstimate -FileGb 13.1 -BandwidthGiBps '' -Offload 'gpu-all')) "blank bandwidth returns null"
    Assert-True ($null -eq (Get-AirlockSpeedEstimate -FileGb 0 -BandwidthGiBps 100 -Offload 'gpu-all')) "FileGb 0 returns null"
    $gpuSpeed = Get-AirlockSpeedEstimate -FileGb 13.1 -BandwidthGiBps 100 -Offload 'gpu-all'
    Assert-True ($gpuSpeed.ToksPerSec -eq [math]::Round((100 * 0.5) / 13.1, 2)) "gpu-all tok/s uses efficiency 0.5"
    Assert-True ($gpuSpeed.Formula -eq 'tok/s ~= bandwidthGiBps * efficiency / fileGiB') "speed formula text is exact"
    Assert-True (-not ($gpuSpeed.PSObject.Properties.Name -contains 'InheritEvidence')) "speed estimate has no InheritEvidence field"
    $cpuSpeed = Get-AirlockSpeedEstimate -FileGb 13.1 -BandwidthGiBps 100 -Offload 'cpu'
    Assert-True ($cpuSpeed.Efficiency -eq 0.15) "cpu efficiency is 0.15"
    Assert-True ($cpuSpeed.ToksPerSec -eq [math]::Round((100 * 0.15) / 13.1, 2)) "cpu tok/s uses efficiency 0.15"
    Assert-True (-not ($cpuSpeed.PSObject.Properties.Name -contains 'InheritEvidence')) "cpu speed estimate has no InheritEvidence field"

    $evidencePick = Format-AirlockPickLine -HardwareName 'RTX 5000 Ada' -FreeGb 15 -RamGb 64 -Quant 'UD-Q3_K_XL' -Mode 'gpu' -InheritEvidence $true -ContextTokens 8192 -Fit 'Marginal'
    $evidenceLines = @($evidencePick -split "`n")
    Assert-True ($evidenceLines.Count -eq 2) "evidence pick line is exactly two lines"
    Assert-True ($evidenceLines[0] -eq 'hardware    RTX 5000 Ada    15 GB free    64 GB RAM') "hardware line shape"
    Assert-True ($evidenceLines[1] -eq 'pick        UD-Q3_K_XL    gpu    evidence    ctx 8192    fit Marginal') "evidence follows InheritEvidence"
    $candidatePick = Format-AirlockPickLine -HardwareName 'RX 7800 XT' -FreeGb 15 -RamGb 32 -Quant 'UD-Q3_K_XL' -Mode 'cpu' -InheritEvidence $false -ContextTokens 4096 -Fit 'Good'
    $candidateLines = @($candidatePick -split "`n")
    Assert-True ($candidateLines.Count -eq 2) "candidate pick line is exactly two lines"
    Assert-True ($candidateLines[1] -eq 'pick        UD-Q3_K_XL    cpu    candidate    ctx 4096    fit Good') "candidate follows InheritEvidence false"

    $failedDoc = Format-AirlockHardwareDoctor -Pool $null -Pick $null -SpeedLine $null
    Assert-True ($failedDoc -match 'detection failed') "no GPU and null RAM says detection failed"
    Assert-True ($failedDoc -match 'certificate: candidate') "detection failure certificate is candidate"
    Assert-True ($failedDoc -match 'AMD/Intel were not probed') "detection failure says AMD/Intel were not probed"
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
    Assert-True (-not (Test-Path (Join-Path $whatIfDir "logs" "hardware-doctor.txt"))) "T7: WhatIf explicit profile does not write hardware-doctor.txt"
} finally {
    Remove-Item -Path $whatIfDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- T8 / D7: Ollama coding certificate is refused unless a live pass this run ---
. (Join-Path $ScriptDir "agent-profile-helpers.ps1")
$cmdOllama = Get-Command Resolve-AirlockOllamaCodingCertificate -ErrorAction SilentlyContinue
Assert-True ([bool]$cmdOllama) "T8: Resolve-AirlockOllamaCodingCertificate exists"
$doctorRoot = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-hardware-doctor-$([guid]::NewGuid().ToString('N'))"
try {
    Save-AirlockHardwareDoctor -PlatformDir $doctorRoot -Text "hardware-doctor`ndetection failed" -WhatIf
    Assert-True (-not (Test-Path (Join-Path $doctorRoot 'logs'))) "WhatIf Save-AirlockHardwareDoctor creates no logs directory"
    Assert-True (-not (Test-Path (Join-Path $doctorRoot 'logs' 'hardware-doctor.txt'))) "WhatIf Save-AirlockHardwareDoctor writes no doctor file"
    Save-AirlockHardwareDoctor -PlatformDir $doctorRoot -Text "hardware-doctor`ncertificate: candidate" -WhatIf:$false
    $doctorPath = Join-Path $doctorRoot 'logs' 'hardware-doctor.txt'
    Assert-True (Test-Path $doctorPath) "Save-AirlockHardwareDoctor writes logs/hardware-doctor.txt when WhatIf is false"
    $doctorBody = Get-Content -Path $doctorPath -Raw
    Assert-True ($doctorBody -match 'certificate: candidate') "written doctor text is the text that was passed"
} finally {
    Remove-Item -Path $doctorRoot -Recurse -Force -ErrorAction SilentlyContinue
}
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
Assert-True ($sessionText -match 'Save-AirlockHardwareDoctor') "sizing path calls Save-AirlockHardwareDoctor"
Assert-True ($sessionText -match '\$script:AirlockCertificateTtlHours\s*=\s*24') "certificate TTL named constant is 24 hours"
Assert-True ($sessionText -match 'AddHours\(\$script:AirlockCertificateTtlHours\)') "expiresAt uses AirlockCertificateTtlHours (24h), not 5 minutes"
Assert-True ($sessionText -notmatch 'expiresAt\s+=\s+\[DateTime\]::UtcNow\.AddMinutes\(5\)') "expiresAt is not now+5 minutes"
Assert-True ($sessionText -match 'Write-Host \$fitState\.Message') "portable-fit fail-fast prints Resolve-AirlockPortableFitState.Message (Unsloth ladder / live Pi 3/3 / do-not-inherit)"

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
$stopText = Get-Content (Join-Path $ScriptDir "Stop-AI.ps1") -Raw
Assert-True ($stopText -match 'Stop-LlamaCppIfOwned') "MVP: ai-stop stops llama-server instances this platform started"
Assert-True ($stopText -match 'llamacpp-embedding-instance.json') "MVP: ai-stop also stops the embedding runtime, not just the 27B"

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
