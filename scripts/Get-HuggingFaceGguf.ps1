# Get-HuggingFaceGguf.ps1 — AIR-016 D3
# llama-server GGUF acquire. Does NOT call `ollama create`. The Ollama HF
# importer (Start-HuggingFaceImport in Get-ModelAcquisition.ps1) stays
# untouched for chat fallback.
# Pure decision functions are unit-tested in Test-AgentStart.ps1 with no
# network. Get-AirlockHuggingFaceGguf is the I/O wrapper.

$script:AirlockGgufEvidenceBytes = [long]13146393504

$script:AirlockGgufFileMap = @{
    'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL' = 'Qwen3.8-27B-UD-Q3_K_XL.gguf'
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
