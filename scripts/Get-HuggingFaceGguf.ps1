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
        [pscustomobject]@{ Quant = 'UD-Q4_K_XL'; FileGb = 17.6; MinimumFreeVramGiB = 20; CodingDefault = $false; Role = '24gb-quality' }
    )
}

function ConvertTo-AirlockUnslothModelRef {
    param([Parameter(Mandatory)][string]$Quant)
    return "unsloth/Qwen3.8-27B-GGUF:$Quant"
}

# Pure: pick a Unsloth Dynamic 3.0 quant for THIS machine.
# GPU-all is the fast coding door. When VRAM is short but system RAM can
# hold the GGUF (llama.cpp mmap — what people mean by "I ran 70B on RAM"),
# return CpuOffload: same weights, --n-gpu-layers 0, slow, live Pi required.
# Never inherit a GPU 3/3 onto a CPU run. 1-bit still refused.
function Resolve-AirlockUnslothQuantStrategy {
    param(
        [AllowNull()]$GpuTotalGb,
        [AllowNull()]$FreeVramGiB,
        [AllowNull()]$FreeRamGb
    )
    $q3 = ConvertTo-AirlockUnslothModelRef -Quant 'UD-Q3_K_XL'
    $gpuOk = ($null -ne $GpuTotalGb -and $null -ne $FreeVramGiB)
    if ($gpuOk) {
        $total = [double]$GpuTotalGb
        $free = [double]$FreeVramGiB
        if ($total -ge 16 -and $free -ge 14) {
            return [pscustomobject]@{
                Action               = 'UseDefault'
                Quant                = 'UD-Q3_K_XL'
                ModelRef             = $q3
                InheritEvidence      = $true
                Offload              = 'gpu-all'
                MinimumFreeVramGiB   = 14
                Reason               = "RTX-class ${total} GB, $free GiB free: coding default UD-Q3_K_XL (14 GiB floor, 3/3). Q4_K_XL is 17.6 GB and spills on 16 GB."
            }
        }
        if ($free -ge 12) {
            return [pscustomobject]@{
                Action               = 'StepDown'
                Quant                = 'UD-IQ3_XXS'
                ModelRef             = (ConvertTo-AirlockUnslothModelRef -Quant 'UD-IQ3_XXS')
                InheritEvidence      = $false
                Offload              = 'gpu-all'
                MinimumFreeVramGiB   = 12
                Reason               = "$free GiB free is below the Q3_K_XL 14 GiB floor. Step down to UD-IQ3_XXS (more KV). candidateOnly; live contract required."
            }
        }
        if ($free -ge 11) {
            return [pscustomobject]@{
                Action               = 'StepDown'
                Quant                = 'UD-Q2_K_XL'
                ModelRef             = (ConvertTo-AirlockUnslothModelRef -Quant 'UD-Q2_K_XL')
                InheritEvidence      = $false
                Offload              = 'gpu-all'
                MinimumFreeVramGiB   = 11
                Reason               = "$free GiB free: UD-Q2_K_XL step-down. Quality cost is real. candidateOnly; live contract required."
            }
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
            $vramNote = if ($gpuOk) { "$([math]::Round([double]$FreeVramGiB, 2)) GiB VRAM" } else { 'no NVIDIA GPU' }
            return [pscustomobject]@{
                Action               = 'CpuOffload'
                Quant                = $cpuPick
                ModelRef             = (ConvertTo-AirlockUnslothModelRef -Quant $cpuPick)
                InheritEvidence      = $false
                Offload              = 'cpu'
                MinimumFreeVramGiB   = 0
                Reason               = "$vramNote; $([math]::Round($ram, 1)) GiB RAM: mmap $cpuPick on CPU (--n-gpu-layers 0). This is the 'run it on RAM' path. Slow (often 1-5 tok/s). Tools can still work. Live Pi on THIS PC required; do not inherit a GPU 3/3."
            }
        }
    }

    if (-not $gpuOk) {
        return [pscustomobject]@{
            Action               = 'Refuse'
            Quant                = $null
            ModelRef             = $null
            InheritEvidence      = $false
            Offload              = 'none'
            MinimumFreeVramGiB   = 14
            Reason               = 'cannot measure GPU/VRAM, and RAM is missing or too small for a Unsloth mmap. Refusing a coding quant pick.'
        }
    }
    return [pscustomobject]@{
        Action               = 'Refuse'
        Quant                = $null
        ModelRef             = $null
        InheritEvidence      = $false
        Offload              = 'none'
        MinimumFreeVramGiB   = 14
        Reason               = "$([math]::Round([double]$FreeVramGiB, 2)) GiB VRAM is below the GPU coding floor and RAM is missing or too small for mmap. Do not load 1-bit. Use ai-start for chat."
    }
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
