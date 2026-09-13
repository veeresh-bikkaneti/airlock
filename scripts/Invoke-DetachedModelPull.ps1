# Detached Ollama pull / HuggingFace import. Survives the parent PowerShell session.
param(
    [Parameter(Mandatory)]
    [ValidateSet('pull', 'import')]
    [string]$Kind,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$LogFile,
    [string]$ProgressFile,
    [string]$RepoId,
    [string]$Filename,
    [string]$Url,
    [double]$SizeGB
)

if (-not $ProgressFile) {
    $ProgressFile = Join-Path $env:USERPROFILE ".ai-platform\.pull-progress.json"
}

$statePath = Join-Path $env:USERPROFILE ".ai-platform\state\model-pull.json"
$provider = if ($Kind -eq 'import') { 'huggingface' } else { 'ollama' }
$kindTag = if ($Kind -eq 'import') { 'hf-import' } else { 'ollama-pull' }

function Write-JobAuditLog {
    param([string]$Action, [string]$Result, [string]$Message, [string]$Detail = "")
    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        user         = $env:USERNAME
        host         = $env:COMPUTERNAME
        action       = $Action
        result       = $Result
        provider     = $script:provider
        model        = $script:Model
        endpoint     = ""
        message      = $Message
        detail       = $Detail
    }
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $script:LogFile -Encoding utf8
}

function ConvertFrom-OllamaPullLine {
    param([Parameter(Mandatory)][string]$Line)
    $pattern = 'pulling\s+\S+:\s*(\d+)%.*?([\d.]+\s*\w+)\s*/\s*([\d.]+\s*\w+)(?:\s+([\d.]+\s*\w+/s))?\s*(\d+[a-zA-Z]+)?'
    if ($Line -match $pattern) {
        return [pscustomobject]@{
            Percent    = [int]$Matches[1]
            Downloaded = $Matches[2]
            Total      = $Matches[3]
            Speed      = $Matches[4]
            Eta        = $Matches[5]
        }
    }
    return $null
}

$script:PullLastResult = 'SUCCESS'

function Write-PullTerminalState {
    param([Parameter(Mandatory)][string]$Result)
    $script:PullLastResult = $Result
    $dir = Split-Path -Parent $script:statePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ([ordered]@{
        pid        = 0
        model      = $script:Model
        startedAt  = [DateTime]::UtcNow.ToString("o")
        kind       = $script:kindTag
        lastResult = $Result
        finishedAt = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Compress) | Set-Content -Path $script:statePath -Encoding utf8NoBOM
}

function Clear-OwnPullState {
    if ($script:PullLastResult -eq 'FAILED') { return }
    if (-not (Test-Path $script:statePath)) { return }
    try {
        $st = Get-Content $script:statePath -Raw | ConvertFrom-Json
        if ([int]$st.pid -eq $PID) {
            Remove-Item $script:statePath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Invoke-ModelWarmStart {
    param([string]$Message)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(120)
        $body = [System.Net.Http.StringContent]::new(
            (@{ model = $script:Model } | ConvertTo-Json -Compress),
            [System.Text.Encoding]::UTF8, "application/json")
        $warmResp = $c.PostAsync("http://127.0.0.1:$($script:Port)/api/generate", $body).Result
        if ($warmResp.IsSuccessStatusCode) {
            Write-JobAuditLog -Action "ModelStarted" -Result "SUCCESS" -Message $Message
        } else {
            Write-JobAuditLog -Action "ModelStarted" -Result "WARNING" -Message "Warm-up call failed" -Detail "HTTP $($warmResp.StatusCode)"
        }
    } catch {
        Write-JobAuditLog -Action "ModelStarted" -Result "WARNING" -Message "Warm-up call failed" -Detail $_.Exception.Message
    }
}

$ollamaDefaultPath = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
if (-not (Get-Command ollama -ErrorAction SilentlyContinue) -and (Test-Path $ollamaDefaultPath)) {
    $env:Path = "$(Split-Path -Parent $ollamaDefaultPath);$env:Path"
}

$stateDir = Split-Path -Parent $statePath
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
([ordered]@{
    pid       = $PID
    model     = $Model
    startedAt = [DateTime]::UtcNow.ToString("o")
    kind      = $kindTag
} | ConvertTo-Json -Compress) | Set-Content -Path $statePath -Encoding utf8NoBOM

try {
    if ($Kind -eq 'pull') {
        try {
        & ollama pull $Model 2>&1 | ForEach-Object {
            $parsed = ConvertFrom-OllamaPullLine -Line $_.ToString()
            if ($parsed) {
                $progress = [ordered]@{
                    model      = $Model
                    percent    = $parsed.Percent
                    downloaded = $parsed.Downloaded
                    total      = $parsed.Total
                    speed      = $parsed.Speed
                    eta        = $parsed.Eta
                    updatedUtc = [DateTime]::UtcNow.ToString("o")
                }
                try { ($progress | ConvertTo-Json -Compress) | Set-Content -Path $ProgressFile -Encoding utf8NoBOM } catch {}
            }
        }
        Remove-Item $ProgressFile -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -eq 0) {
            Write-JobAuditLog -Action "ModelPull" -Result "SUCCESS" -Message "Model pulled in background"
            Invoke-ModelWarmStart -Message "Model auto-started after background pull"
        } else {
            Write-JobAuditLog -Action "ModelPull" -Result "FAILED" -Message "ollama pull failed"
            Write-PullTerminalState -Result 'FAILED'
        }
        } catch {
            Write-JobAuditLog -Action "ModelPull" -Result "FAILED" -Message "ollama pull threw" -Detail $_.Exception.Message
            Write-PullTerminalState -Result 'FAILED'
        }
    } else {
        $downloadDir = Join-Path $env:USERPROFILE ".ai-platform\models"
        if (-not (Test-Path $downloadDir)) {
            New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        }
        $safeFilename = (Split-Path -Leaf $Filename) -replace '[^a-zA-Z0-9._-]', ''
        $filepath = Join-Path $downloadDir $safeFilename
        try {
            Write-JobAuditLog -Action "HuggingFaceDownload" -Result "STARTED" `
                -Message "Downloading $RepoId/$Filename from HuggingFace" `
                -Detail "Size: $SizeGB GB"
            Invoke-WebRequest -Uri $Url -OutFile $filepath -TimeoutSec 3600 -ErrorAction Stop
            if ((Test-Path $filepath) -and ((Get-Item $filepath).Length -gt 0)) {
                Write-JobAuditLog -Action "HuggingFaceDownload" -Result "SUCCESS" `
                    -Message "Downloaded $Filename ($SizeGB GB)" `
                    -Detail "Saved to: $filepath"
                $modelfilePath = Join-Path $downloadDir "$Model.modelfile"
                "FROM $filepath" | Set-Content -Path $modelfilePath -Encoding utf8
                Write-JobAuditLog -Action "HuggingFaceImport" -Result "STARTED" `
                    -Message "Importing GGUF into Ollama: $Model"
                & ollama create $Model -f $modelfilePath
                Remove-Item -Path $modelfilePath -Force -ErrorAction SilentlyContinue
                if ($LASTEXITCODE -eq 0) {
                    Write-JobAuditLog -Action "HuggingFaceImport" -Result "SUCCESS" `
                        -Message "Model imported successfully: $Model"
                    Invoke-ModelWarmStart -Message "Model auto-started after HuggingFace import"
                } else {
                    Write-JobAuditLog -Action "HuggingFaceImport" -Result "FAILED" `
                        -Message "ollama create failed for $Model"
                    Write-PullTerminalState -Result 'FAILED'
                }
            } else {
                Remove-Item -Path $filepath -Force -ErrorAction SilentlyContinue
                Write-JobAuditLog -Action "HuggingFaceDownload" -Result "FAILED" `
                    -Message "Download failed or file is empty" -Detail "Path: $filepath"
                Write-PullTerminalState -Result 'FAILED'
            }
        } catch {
            Remove-Item -Path $filepath -Force -ErrorAction SilentlyContinue
            Write-JobAuditLog -Action "HuggingFaceDownload" -Result "FAILED" `
                -Message "Error downloading GGUF from HuggingFace" -Detail $_.Exception.Message
            Write-PullTerminalState -Result 'FAILED'
        }
    }
} finally {
    Clear-OwnPullState
}
