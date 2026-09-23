# Get-HuggingFaceGguf.ps1 — AIR-016 D3
# llama-server GGUF acquire. Does NOT call `ollama create`. The Ollama HF
# importer (Start-HuggingFaceImport in Get-ModelAcquisition.ps1) stays
# untouched for chat fallback.
# Pure decision functions are unit-tested in Test-AgentStart.ps1 with no
# network. Get-AirlockHuggingFaceGguf is the I/O wrapper.

$script:AirlockGgufEvidenceBytes = [long]13146393504

# Cold-machine fix: storage preflight lives in StoragePreflight.ps1; guard the
# dot-source so this file also works when dot-sourced on its own (tests).
if (-not (Get-Command Test-StoragePreflight -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "StoragePreflight.ps1")
}

$script:AirlockGgufFileMap = @{
    'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL'  = 'Qwen3.8-27B-UD-Q3_K_XL.gguf'
    'unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS'  = 'Qwen3.8-27B-UD-IQ3_XXS.gguf'
    'unsloth/Qwen3.8-27B-GGUF:UD-Q2_K_XL'  = 'Qwen3.8-27B-UD-Q2_K_XL.gguf'
    'unsloth/Qwen3.8-27B-GGUF:UD-IQ2_XXS'  = 'Qwen3.8-27B-UD-IQ2_XXS.gguf'
    'unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL'  = 'Qwen3.8-27B-UD-Q4_K_XL.gguf'
    'unsloth/Qwen3.8-27B-GGUF:UD-Q5_K_XL'  = 'Qwen3.8-27B-UD-Q5_K_XL.gguf'
    'unsloth/Qwen3.8-27B-GGUF:UD-Q6_K_XL'  = 'Qwen3.8-27B-UD-Q6_K_XL.gguf'
    'unsloth/Qwen3.8-27B-GGUF:UD-Q8_K_XL'  = 'Qwen3.8-27B-UD-Q8_K_XL.gguf'
}

# Unsloth Dynamic 3.0 ladder for Qwen3.8-27B. FileGb is the HF advertised
# size. CodingDefault is the only row that may inherit the 3/3, and only
# when the on-disk byte length matches AirlockGgufEvidenceBytes.
# See docs/adr/ADR-018-unsloth-quantization-strategy.md.
function Get-AirlockUnslothQuantLadder {
    return @(
        [pscustomobject]@{ Quant = 'UD-IQ2_XXS'; FileGb = 7.27; MinimumFreeVramGiB = 9;  CodingDefault = $false; Role = 'last-resort-12gb' }
        [pscustomobject]@{ Quant = 'UD-Q2_K_XL'; FileGb = 9.83; MinimumFreeVramGiB = 11; CodingDefault = $false; Role = 'step-down' }
        [pscustomobject]@{ Quant = 'UD-IQ3_XXS'; FileGb = 10.9; MinimumFreeVramGiB = 12; CodingDefault = $false; Role = 'step-down-kv' }
        [pscustomobject]@{ Quant = 'UD-Q3_K_XL'; FileGb = 13.1; MinimumFreeVramGiB = 14; CodingDefault = $true;  Role = 'coding-default' }
        [pscustomobject]@{ Quant = 'UD-IQ4_XS';  FileGb = 14.3; MinimumFreeVramGiB = 16; CodingDefault = $false; Role = 'spill-on-16gb' }
        [pscustomobject]@{ Quant = 'UD-Q4_K_XL'; FileGb = 17.6; MinimumFreeVramGiB = 20; CodingDefault = $false; Role = 'step-up' }
        [pscustomobject]@{ Quant = 'UD-Q5_K_XL'; FileGb = 20.9; MinimumFreeVramGiB = 24; CodingDefault = $false; Role = 'step-up' }
        [pscustomobject]@{ Quant = 'UD-Q6_K_XL'; FileGb = 25.3; MinimumFreeVramGiB = 28; CodingDefault = $false; Role = 'step-up' }
        [pscustomobject]@{ Quant = 'UD-Q8_K_XL'; FileGb = 31.5; MinimumFreeVramGiB = 34; CodingDefault = $false; Role = 'step-up' }
    )
}

function ConvertTo-AirlockUnslothModelRef {
    param([Parameter(Mandatory)][string]$Quant)
    return "unsloth/Qwen3.8-27B-GGUF:$Quant"
}

function Get-AirlockMemoryFitLevel {
    param(
        [Parameter(Mandatory)][double]$RequiredGb,
        [Parameter(Mandatory)][double]$AvailableGb,
        [Parameter(Mandatory)][string]$Offload
    )
    if ($AvailableGb -le 0) { return 'TooTight' }
    $ratio = $RequiredGb / $AvailableGb
    $level = if ($ratio -le 0.60) { 'Perfect' }
             elseif ($ratio -le 0.85) { 'Good' }
             elseif ($ratio -le 0.98) { 'Marginal' }
             else { 'TooTight' }
    # CPU and split runs can look roomy and still be slow. Perfect means GPU-all.
    if ($Offload -ne 'gpu-all' -and $level -eq 'Perfect') { return 'Good' }
    return $level
}

function New-AirlockUnslothPick {
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Quant,
        [bool]$InheritEvidence,
        [Parameter(Mandatory)][string]$Offload,
        [double]$MinimumFreeVramGiB,
        [string]$Fit,
        [int]$ContextTokens = 0,
        [string]$SpeedLine = '',
        [Parameter(Mandatory)][string]$Reason
    )
    $ref = if ($Quant) { ConvertTo-AirlockUnslothModelRef -Quant $Quant } else { $null }
    return [pscustomobject]@{
        Action             = $Action
        Quant              = $Quant
        ModelRef           = $ref
        InheritEvidence    = $InheritEvidence
        Offload            = $Offload
        MinimumFreeVramGiB = $MinimumFreeVramGiB
        Fit                = $Fit
        ContextTokens      = $ContextTokens
        SpeedLine          = $SpeedLine
        Reason             = $Reason
    }
}

function Get-AirlockHalfContextFloorGiB {
    param(
        [Parameter(Mandatory)][double]$FileGb,
        [Parameter(Mandatory)][double]$FullFloorGiB
    )
    return $FileGb + ($FullFloorGiB - $FileGb) / 2
}

function Get-AirlockSpeedEstimate {
    param(
        [double]$FileGb,
        $BandwidthGiBps,
        [string]$Offload
    )
    # Missing bandwidth or a zero file size is not an estimate, and this
    # object never carries InheritEvidence. Efficiency is named per offload.
    if ($FileGb -le 0) { return $null }
    if ($null -eq $BandwidthGiBps -or [string]$BandwidthGiBps -eq '') { return $null }
    $gpuAllEfficiency = 0.5
    $cpuEfficiency = 0.15
    $efficiency = switch ($Offload) {
        'gpu-all' { $gpuAllEfficiency }
        'cpu'     { $cpuEfficiency }
        default   { $null }
    }
    if ($null -eq $efficiency) { return $null }
    $bw = [double]$BandwidthGiBps
    $toks = [math]::Round(($bw * $efficiency) / $FileGb, 2)
    return [pscustomobject]@{
        ToksPerSec = $toks
        Efficiency = $efficiency
        Formula    = "tok/s ~= bandwidthGiBps * efficiency / fileGiB"
        Line       = "speed ~$toks tok/s estimate (tok/s ~= $bw * $efficiency / $FileGb)"
    }
}

function Resolve-AirlockGpuPool {
    param(
        [object[]]$Gpus = @(),
        $FreeRamGb
    )
    $amdSentence = 'Windows AMD is not the NVIDIA evidence path; expect a Vulkan or ROCm llama-server, not CUDA; live Pi required.'
    $list = @($Gpus | Where-Object { $_ })
    $discrete = @($list | Where-Object { -not $_.Unified })
    $ram = if ($null -eq $FreeRamGb) { $null } else { [double]$FreeRamGb }
    if ($discrete.Count -eq 0) {
        return [pscustomobject]@{
            Chosen       = $null
            UseRam       = $true
            FreeRamGb    = $ram
            AmdNote      = $null
            Reason       = 'no discrete GPU; unified memory is not VRAM and is not added. Pool is free RAM.'
            Devices      = $list
        }
    }
    $ordered = @($discrete | Sort-Object @{ Expression = { [double]$_.FreeGiB }; Descending = $true }, @{ Expression = { [double]$_.TotalGiB }; Descending = $true })
    $chosen = $ordered[0]
    $others = @($list | Where-Object { $_.Name -ne $chosen.Name -or $_.FreeGiB -ne $chosen.FreeGiB })
    $notAdded = if ($others.Count -gt 0) { ' not added: ' + (($others | ForEach-Object { "$($_.Name) $([math]::Round([double]$_.FreeGiB, 2)) GiB free" }) -join ', ') } else { '' }
    $vendor = if ($chosen.Vendor) { [string]$chosen.Vendor } else { '' }
    $amd = if ($vendor.Trim().ToUpperInvariant() -eq 'AMD') { $amdSentence } else { $null }
    return [pscustomobject]@{
        Chosen    = $chosen
        UseRam    = $false
        FreeRamGb = $ram
        AmdNote   = $amd
        Reason    = "using $($chosen.Name) ($([math]::Round([double]$chosen.FreeGiB, 2)) GiB free).$notAdded"
        Devices   = $list
    }
}

function Format-AirlockPickLine {
    param(
        [string]$HardwareName,
        $FreeGb,
        $RamGb,
        [string]$Quant,
        [string]$Mode,
        [bool]$InheritEvidence,
        [int]$ContextTokens,
        [string]$Fit
    )
    $trust = if ($InheritEvidence) { 'evidence' } else { 'candidate' }
    $quantText = if ($Quant) { $Quant } else { 'none' }
    $freeText = if ($null -eq $FreeGb) { 'unknown' } else { $FreeGb }
    $ramText = if ($null -eq $RamGb) { 'unknown' } else { $RamGb }
    $fitText = if ($Fit) { $Fit } else { 'none' }
    return @(
        "hardware    $HardwareName    $freeText GB free    $ramText GB RAM"
        "pick        $quantText    $Mode    $trust    ctx $ContextTokens    fit $fitText"
    ) -join "`n"
}

function Format-AirlockHardwareDoctor {
    param(
        $Pool,
        $Pick,
        [string]$SpeedLine
    )
    $devices = @()
    if ($Pool -and $Pool.Devices) { $devices = @($Pool.Devices) }
    $lines = @('hardware-doctor')
    if ($devices.Count -eq 0 -and ($null -eq $Pool -or $null -eq $Pool.FreeRamGb)) {
        $lines += 'detection failed: no GPU list and no RAM. AMD/Intel were not probed.'
        $lines += 'certificate: candidate'
        return ($lines -join "`n")
    }
    foreach ($gpu in $devices) {
        $flag = if ($gpu.Unified) { 'unified' } else { 'discrete' }
        $lines += "gpu $($gpu.Name) vendor=$($gpu.Vendor) free=$($gpu.FreeGiB) total=$($gpu.TotalGiB) $flag"
    }
    if ($Pool -and $Pool.Chosen) {
        $lines += "chosen $($Pool.Chosen.Name); other devices not added"
    } elseif ($Pool) {
        $lines += $Pool.Reason
    }
    if ($Pool -and $Pool.AmdNote) {
        $lines += [string]$Pool.AmdNote
    }
    if (-not ($Pool -and $Pool.Chosen) -and ($devices | Where-Object { -not $_.Vendor })) {
        $lines += 'nvidia-smi did not identify a vendor and AMD/Intel were not probed.'
    }
    if ($Pool -and $null -eq $Pool.Chosen -and $devices.Count -eq 0) {
        $lines += 'unknown vendor: nvidia-smi did not identify a vendor and AMD/Intel were not probed.'
    }
    $ram = if ($Pool) { $Pool.FreeRamGb } else { $null }
    $lines += "ram $ram"
    if ($Pick) {
        $mode = switch ($Pick.Offload) {
            'gpu-all' { 'gpu' }
            'cpu'     { 'cpu' }
            default   { 'none' }
        }
        $cert = if ($Pick.InheritEvidence) { 'certificate: evidence-quant' } else { 'certificate: candidate' }
        $lines += "pick $($Pick.Quant) fit=$($Pick.Fit) ctx=$($Pick.ContextTokens) mode=$mode"
        $lines += $cert
    }
    if ($SpeedLine) { $lines += $SpeedLine } else { $lines += 'speed unknown' }
    return ($lines -join "`n")
}

# Named machines the ladder can be checked against without owning the card.
# Numbers are free-pool examples, not certificates.
function Get-AirlockHardwareProfiles {
    return @(
        [pscustomobject]@{ Name = 'thinkpad-rtx-5000-ada-16'; Vendor = 'NVIDIA'; GpuTotalGb = 16; FreeVramGiB = 15; FreeRamGb = 64 }
        [pscustomobject]@{ Name = 'rtx-4090-24';              Vendor = 'NVIDIA'; GpuTotalGb = 24; FreeVramGiB = 22; FreeRamGb = 64 }
        [pscustomobject]@{ Name = 'rtx-5090-32';              Vendor = 'NVIDIA'; GpuTotalGb = 32; FreeVramGiB = 30; FreeRamGb = 64 }
        [pscustomobject]@{ Name = 'rtx-a6000-48';             Vendor = 'NVIDIA'; GpuTotalGb = 48; FreeVramGiB = 44; FreeRamGb = 128 }
        [pscustomobject]@{ Name = 'rx-7800-xt-16';            Vendor = 'AMD';    GpuTotalGb = 16; FreeVramGiB = 15; FreeRamGb = 32 }
        [pscustomobject]@{ Name = 'cpu-32gb';                 Vendor = 'CPU';    GpuTotalGb = $null; FreeVramGiB = $null; FreeRamGb = 32 }
    )
}

function Resolve-AirlockUnslothQuantForProfile {
    param([Parameter(Mandatory)][string]$Name)
    $profile = Get-AirlockHardwareProfiles | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $profile) { throw "unknown hardware profile '$Name'" }
    return Resolve-AirlockUnslothQuantStrategy -GpuTotalGb $profile.GpuTotalGb -FreeVramGiB $profile.FreeVramGiB -FreeRamGb $profile.FreeRamGb -Vendor $profile.Vendor
}

# Pure: pick a Unsloth Dynamic 3.0 quant for THIS machine.
# GPU-all walks the closed ladder and keeps the highest quality whose floor
# fits free VRAM. That steps up on a bigger card and down on a smaller one.
# The ThinkPad 3/3 is inherited only for UD-Q3_K_XL on a 16 GB NVIDIA-class
# card. Every other pick is candidateOnly. CPU mmap never inherits, and its
# fit label is capped at Good.
function Resolve-AirlockUnslothQuantStrategy {
    param(
        [AllowNull()]$GpuTotalGb,
        [AllowNull()]$FreeVramGiB,
        [AllowNull()]$FreeRamGb,
        [string]$Vendor = '',
        [bool]$Unified = $false,
        [string]$AmdNote = ''
    )
    $vendorName = if ($Vendor) { $Vendor.Trim().ToUpperInvariant() } else { '' }
    $amd = if ($AmdNote) { " $AmdNote" } elseif ($vendorName -eq 'AMD') { ' Windows AMD is not the NVIDIA evidence path; expect a Vulkan or ROCm llama-server, not CUDA; live Pi required.' } else { '' }
    $gpuOk = (-not $Unified -and $null -ne $GpuTotalGb -and $null -ne $FreeVramGiB)
    if ($gpuOk) {
        $total = [double]$GpuTotalGb
        $free = [double]$FreeVramGiB
        $rows = @(Get-AirlockUnslothQuantLadder | Where-Object { $_.Role -ne 'spill-on-16gb' } | Sort-Object { [double]$_.MinimumFreeVramGiB } -Descending)
        $picked = $null
        $context = 8192
        $usedFloor = 0
        foreach ($candidate in $rows) {
            $full = [double]$candidate.MinimumFreeVramGiB
            $half = Get-AirlockHalfContextFloorGiB -FileGb ([double]$candidate.FileGb) -FullFloorGiB $full
            if ($free -ge $full) {
                $picked = $candidate
                $context = if ($candidate.Quant -eq 'UD-IQ2_XXS') { 4096 } else { 8192 }
                $usedFloor = $full
                break
            }
            if ($free -ge $half) {
                $picked = $candidate
                $context = 4096
                $usedFloor = $half
                break
            }
        }
        if ($picked) {
            $inherit = ($picked.Quant -eq 'UD-Q3_K_XL' -and $picked.CodingDefault -and $context -eq 8192 -and $vendorName -eq 'NVIDIA' -and $total -ge 15 -and $total -lt 18 -and -not $Unified)
            $action = if ($inherit) { 'UseDefault' }
                      elseif ([double]$picked.MinimumFreeVramGiB -gt 14) { 'StepUp' }
                      elseif ([double]$picked.MinimumFreeVramGiB -lt 14) { 'StepDown' }
                      else { 'UseCandidate' }
            $fit = Get-AirlockMemoryFitLevel -RequiredGb ([double]$picked.FileGb) -AvailableGb $free -Offload 'gpu-all'
            $who = if ($vendorName) { "$vendorName $total GB" } else { "$total GB" }
            $reason = switch ($action) {
                'UseDefault' { "$who, $free GiB free: coding default UD-Q3_K_XL at ctx $context. Fit $fit." }
                'StepUp'     { "$who, $free GiB free: best closed-catalog quant $($picked.Quant) at ctx $context ($($picked.FileGb) GB, fit $fit). candidateOnly. A 16 GB Q3 certificate does not count here.$amd" }
                'StepDown'   { "$free GiB free is below the next full floor. Step down to $($picked.Quant) at ctx $context. Fit $fit. candidateOnly; live contract required.$amd" }
                default      { "$who, $free GiB free: $($picked.Quant) at ctx $context (fit $fit). Not the 16 GB NVIDIA evidence configuration. candidateOnly; live contract required.$amd" }
            }
            return New-AirlockUnslothPick -Action $action -Quant $picked.Quant -InheritEvidence $inherit -Offload 'gpu-all' -MinimumFreeVramGiB $usedFloor -Fit $fit -ContextTokens $context -Reason $reason
        }
    }

    $ram = if ($null -eq $FreeRamGb) { $null } else { [double]$FreeRamGb }
    if ($null -ne $ram) {
        $cpuPick = $null
        if ($ram -ge 18) { $cpuPick = 'UD-Q3_K_XL' }
        elseif ($ram -ge 14) { $cpuPick = 'UD-IQ3_XXS' }
        elseif ($ram -ge 12) { $cpuPick = 'UD-Q2_K_XL' }
        elseif ($ram -ge 10) { $cpuPick = 'UD-IQ2_XXS' }
        if ($cpuPick) {
            $cpuRow = Get-AirlockUnslothQuantLadder | Where-Object { $_.Quant -eq $cpuPick } | Select-Object -First 1
            $cpuContext = if ($cpuPick -eq 'UD-IQ2_XXS') { 4096 } else { 8192 }
            $fit = Get-AirlockMemoryFitLevel -RequiredGb ([double]$cpuRow.FileGb) -AvailableGb $ram -Offload 'cpu'
            $vramNote = if ($gpuOk) { "$([math]::Round([double]$FreeVramGiB, 2)) GiB VRAM" } else { 'no discrete GPU' }
            return New-AirlockUnslothPick -Action 'CpuOffload' -Quant $cpuPick -InheritEvidence $false -Offload 'cpu' -MinimumFreeVramGiB 0 -Fit $fit -ContextTokens $cpuContext -Reason "$vramNote; $([math]::Round($ram, 1)) GiB RAM: mmap $cpuPick on CPU (--n-gpu-layers 0) at ctx $cpuContext. Fit $fit (CPU is never Perfect). Slow (often 1-5 tok/s). Live Pi on THIS PC required; do not inherit a GPU 3/3.$amd"
        }
    }

    if (-not $gpuOk) {
        return New-AirlockUnslothPick -Action 'Refuse' -Quant $null -InheritEvidence $false -Offload 'none' -MinimumFreeVramGiB 14 -Fit $null -ContextTokens 0 -Reason 'cannot measure GPU/VRAM, and RAM is missing or too small for a Unsloth mmap. Refusing a coding quant pick.'
    }
    return New-AirlockUnslothPick -Action 'Refuse' -Quant $null -InheritEvidence $false -Offload 'none' -MinimumFreeVramGiB 14 -Fit 'TooTight' -ContextTokens 0 -Reason "$([math]::Round([double]$FreeVramGiB, 2)) GiB VRAM is below the GPU coding floor and RAM is missing or too small for mmap. Do not load 1-bit. Use ai-start for chat."
}

function ConvertTo-AirlockGgufFileName {
    param([Parameter(Mandatory)][string]$ModelRef)
    if ($script:AirlockGgufFileMap.ContainsKey($ModelRef)) {
        return $script:AirlockGgufFileMap[$ModelRef]
    }
    if ($ModelRef -match '^[^/]+/([^:]+):(.+)$') {
        $repo = $Matches[1] -replace '-GGUF$', ''
        return "$repo-$($Matches[2]).gguf"
    }
    throw "Cannot map modelRef '$ModelRef' to a GGUF filename"
}

function ConvertTo-AirlockHfRepo {
    param([Parameter(Mandatory)][string]$ModelRef)
    if ($ModelRef -match '^([^/]+/[^:]+):') {
        return $Matches[1]
    }
    throw "Cannot parse HF repo from modelRef '$ModelRef'"
}

function Get-AirlockGgufDestPath {
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [string]$PlatformDir = "$env:USERPROFILE\.ai-platform"
    )
    return Join-Path (Join-Path $PlatformDir "models") (ConvertTo-AirlockGgufFileName -ModelRef $ModelRef)
}

function Test-AirlockGgufEvidenceMatch {
    param([Parameter(Mandatory)][long]$ByteLength)
    return ($ByteLength -eq $script:AirlockGgufEvidenceBytes)
}

function Resolve-AirlockGgufAcquisition {
    param(
        [Parameter(Mandatory)][bool]$DestExists,
        [long]$DestLength = 0,
        [bool]$UserConfirmed = $false
    )
    if ($DestExists -and (Test-AirlockGgufEvidenceMatch -ByteLength $DestLength)) {
        return [pscustomobject]@{
            Action               = 'SkipDownload'
            MatchedEvidenceBytes = $true
            ForceVerify          = $false
            Reason               = "Existing GGUF is exactly $script:AirlockGgufEvidenceBytes bytes - evidence-bound artifact, skip download."
        }
    }
    if ($DestExists) {
        return [pscustomobject]@{
            Action               = 'UseExistingMismatch'
            MatchedEvidenceBytes = $false
            ForceVerify          = $true
            Reason               = "Existing GGUF is $DestLength bytes, not $script:AirlockGgufEvidenceBytes - do not inherit the 3/3; require a live contract."
        }
    }
    if (-not $UserConfirmed) {
        return [pscustomobject]@{
            Action               = 'RequireConfirmation'
            MatchedEvidenceBytes = $false
            ForceVerify          = $true
            Reason               = "GGUF is missing. Re-run with -DownloadConfirmed to fetch ~13 GB (requiresConfirmation: true)."
        }
    }
    return [pscustomobject]@{
        Action               = 'Download'
        MatchedEvidenceBytes = $false
        ForceVerify          = $true
        Reason               = "GGUF missing and download confirmed - fetch from Hugging Face (no ollama create)."
    }
}

function Get-AirlockHuggingFaceGguf {
    param(
        [Parameter(Mandatory)][string]$ModelRef,
        [string]$PlatformDir = "$env:USERPROFILE\.ai-platform",
        [bool]$UserConfirmed = $false
    )
    $dest = Get-AirlockGgufDestPath -ModelRef $ModelRef -PlatformDir $PlatformDir
    $exists = Test-Path $dest
    $length = if ($exists) { [long](Get-Item $dest).Length } else { [long]0 }
    $decision = Resolve-AirlockGgufAcquisition -DestExists $exists -DestLength $length -UserConfirmed $UserConfirmed

    if ($decision.Action -eq 'RequireConfirmation') {
        return [pscustomobject]@{
            Ready                = $false
            Path                 = $dest
            Bytes                = [long]0
            Sha256               = $null
            MatchedEvidenceBytes = $false
            ForceVerify          = $true
            Reason               = $decision.Reason
        }
    }

    if ($decision.Action -eq 'Download') {
        $dir = Split-Path $dest
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        # Cold-machine fix: refuse BEFORE a ~13 GB download when the disk
        # can't hold it, instead of failing mid-download.
        $ladderGb = $null
        try {
            $row = Get-AirlockUnslothQuantLadder | Where-Object { (ConvertTo-AirlockUnslothModelRef -Quant $_.Quant) -eq $ModelRef } | Select-Object -First 1
            if ($row) { $ladderGb = [double]$row.FileGb }
        } catch {}
        $requiredGgufGB = if ($ladderGb) { $ladderGb + 2.0 } else { 15.0 }
        $ggufStorage = Test-StoragePreflight -RequiredGB $requiredGgufGB -Path $dest
        if (-not $ggufStorage.Ok) {
            return [pscustomobject]@{
                Ready                = $false
                Path                 = $dest
                Bytes                = [long]0
                Sha256               = $null
                MatchedEvidenceBytes = $false
                ForceVerify          = $true
                Reason               = "Storage preflight failed: $($ggufStorage.Reason) The coding GGUF (~$([math]::Round($requiredGgufGB,1)) GB needed) was not downloaded."
            }
        }
        $repo = ConvertTo-AirlockHfRepo -ModelRef $ModelRef
        $fileName = ConvertTo-AirlockGgufFileName -ModelRef $ModelRef
        try {
            if (Get-Command hf -ErrorAction SilentlyContinue) {
                & hf download $repo --include "*$fileName*" --local-dir $dir
            } else {
                $url = "https://huggingface.co/$repo/resolve/main/$fileName"
                Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 3600 -ErrorAction Stop
            }
        } catch {
            return [pscustomobject]@{
                Ready                = $false
                Path                 = $dest
                Bytes                = [long]0
                Sha256               = $null
                MatchedEvidenceBytes = $false
                ForceVerify          = $true
                Reason               = "GGUF download failed: $($_.Exception.Message)"
            }
        }
        if (-not (Test-Path $dest) -or ((Get-Item $dest).Length -le 0)) {
            return [pscustomobject]@{
                Ready                = $false
                Path                 = $dest
                Bytes                = [long]0
                Sha256               = $null
                MatchedEvidenceBytes = $false
                ForceVerify          = $true
                Reason               = "GGUF download produced no file at $dest"
            }
        }
        $length = [long](Get-Item $dest).Length
        $decision = Resolve-AirlockGgufAcquisition -DestExists $true -DestLength $length -UserConfirmed $true
    }

    $hash = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{
        Ready                = $true
        Path                 = $dest
        Bytes                = $length
        Sha256               = "sha256:$hash"
        MatchedEvidenceBytes = [bool]$decision.MatchedEvidenceBytes
        ForceVerify          = [bool]$decision.ForceVerify
        Reason               = $decision.Reason
    }
}
