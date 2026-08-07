# Get-ModelAcquisition.ps1 — Model acquisition pipeline (discovery, sizing, selection, background pull)
# Called by scripts/Start-AI.ps1 after Write-AuditLog is defined
# Requires: Write-AuditLog (from Start-AI.ps1)

function Install-OllamaIfMissing {
    # Check if ollama is available on PATH or at the default per-user install location.
    # If not found and winget is available, install via winget. Otherwise, log failure and return $false.

    # Check if ollama is already on PATH.
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        return $true
    }

    # Check default per-user install path.
    $ollamaDefaultPath = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
    if (Test-Path $ollamaDefaultPath) {
        $ollamaDir = Split-Path -Parent $ollamaDefaultPath
        $env:Path = "$ollamaDir;$env:Path"
        return $true
    }

    # Ollama not found anywhere. Check if winget is available.
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        # winget not available: log failure and print error with manual install link.
        Write-AuditLog -Action "OllamaInstall" -Result "FAILED" -Message "Ollama not found and winget unavailable"
        Write-Host "" -ForegroundColor Red
        Write-Host "ERROR: Ollama not found and winget is not available." -ForegroundColor Red
        Write-Host "Please install Ollama manually from: https://ollama.com/download" -ForegroundColor Red
        Write-Host "" -ForegroundColor Red
        return $false
    }

    # winget is available: proceed with installation.
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Ollama not found — installing via winget (one-time, can take several minutes — please wait, don't close this window)..." -ForegroundColor Yellow
    Write-AuditLog -Action "OllamaInstall" -Result "STARTED" -Message "Installing Ollama via winget"

    # Run winget install.
    & winget install --id Ollama.Ollama -e --silent --accept-package-agreements --accept-source-agreements
    $wingetExitCode = $LASTEXITCODE

    if ($wingetExitCode -ne 0) {
        Write-AuditLog -Action "OllamaInstall" -Result "FAILED" -Message "winget install failed" -Detail "Exit code: $wingetExitCode"
        Write-Host "" -ForegroundColor Red
        Write-Host "ERROR: winget install for Ollama failed (exit code: $wingetExitCode)." -ForegroundColor Red
        Write-Host "Please install Ollama manually from: https://ollama.com/download" -ForegroundColor Red
        Write-Host "" -ForegroundColor Red
        return $false
    }

    # Installation succeeded: re-check if ollama is now available.
    if (Test-Path $ollamaDefaultPath) {
        $ollamaDir = Split-Path -Parent $ollamaDefaultPath
        $env:Path = "$ollamaDir;$env:Path"
        Write-Host "Ollama installed successfully via winget." -ForegroundColor Green
        Write-AuditLog -Action "OllamaInstall" -Result "SUCCESS" -Message "Ollama installed via winget"
        return $true
    }

    # Unexpected: winget reported success but ollama exe not found at expected path.
    Write-AuditLog -Action "OllamaInstall" -Result "FAILED" -Message "winget install reported success but Ollama executable not found at expected path"
    Write-Host "" -ForegroundColor Red
    Write-Host "ERROR: Ollama installation reported success, but the executable was not found at the expected location." -ForegroundColor Red
    Write-Host "Please install Ollama manually from: https://ollama.com/download" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    return $false
}

function Get-ModelDiscoverySources {
    # Story 1: discover what's pullable before Test-ResourceAvailability's selection logic scores candidates.
    # Two sources, two log lines - no plugin/registry framework. Ollama has no public
    # "list all pullable models" API, so the curated config/models.json list is the source of truth;
    # Hugging Face's public search API is a secondary, discovery-only check (no download wired up here).
    # Story 2b: HF is only queried when Ollama's curated list has no candidate fitting available hardware.
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][double]$AvailableGB
    )

    $curatedHasMatch = $false
    try {
        $modelsConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $names = $modelsConfig.fallbackOrder -join ", "
        $curatedHasMatch = [bool]($modelsConfig.fallbackOrder | Where-Object {
            $sizeGB = [double]($modelsConfig.localModels.$_.size -replace '[^0-9.]', '')
            $AvailableGB -ge ($sizeGB * 1.2)
        })
        Write-Host "  Discovery: Ollama curated list - $($modelsConfig.fallbackOrder.Count) candidates ($names)" -ForegroundColor Cyan
        Write-AuditLog -Action "ModelDiscovery" -Result "SUCCESS" `
            -Message "Ollama curated list (config/models.json): $($modelsConfig.fallbackOrder.Count) candidates - [$names]" `
            -Detail "Source: config/models.json fallbackOrder; HasFittingMatch=$curatedHasMatch"
    } catch {
        Write-Host "  Discovery: Could not read Ollama curated list from $ConfigPath" -ForegroundColor Yellow
        Write-AuditLog -Action "ModelDiscovery" -Result "WARNING" `
            -Message "Ollama curated list (config/models.json) unreadable" -Detail $_.Exception.Message
    }

    if ($curatedHasMatch) {
        # Acquisition fallback order (docs/05-Provider-Fallback-Matrix.md): Ollama first, HF only when no match.
        Write-Host "  Discovery: Hugging Face GGUF search skipped - Ollama curated list already has a fitting match" -ForegroundColor DarkGray
        Write-AuditLog -Action "ModelDiscovery" -Result "SUCCESS" `
            -Message "Hugging Face GGUF search (secondary source): skipped - Ollama curated list already has a fitting match" `
            -Detail "Skipped per acquisition fallback order: Ollama curated list first, Hugging Face only when no match"
        return
    }

    try {
        $hfUrl = "https://huggingface.co/api/models?search=gguf&filter=gguf&sort=downloads&direction=-1&limit=5"
        $hfResults = Invoke-RestMethod -Uri $hfUrl -TimeoutSec 10
        $hfNames = ($hfResults | Select-Object -First 5 -ExpandProperty id) -join ", "
        Write-Host "  Discovery: Hugging Face GGUF search - $($hfResults.Count) result(s)" -ForegroundColor Cyan
        Write-AuditLog -Action "ModelDiscovery" -Result "SUCCESS" `
            -Message "Hugging Face GGUF search (secondary source): $($hfResults.Count) result(s) - [$hfNames]" `
            -Detail "Endpoint: $hfUrl"
    } catch {
        # Never block startup on this - HF is a secondary source only.
        Write-Host "  Discovery: Hugging Face unreachable (offline?), skipping - secondary source only" -ForegroundColor Yellow
        Write-AuditLog -Action "ModelDiscovery" -Result "WARNING" `
            -Message "Hugging Face GGUF search unreachable; continuing with Ollama curated list only" -Detail $_.Exception.Message
    }
}

function Test-ResourceAvailability {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMemGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeMemGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $memPctFree = [math]::Round(($os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)
    $gpuInfo = $null
    try {
        $nvidia = & nvidia-smi --query-gpu=memory.total,memory.free --format=csv,noheader,nounits 2>$null
        if ($nvidia) {
            $parts = $nvidia.Trim() -split ','
            $gpuInfo = @{ TotalGB = [math]::Round([double]$parts[0] / 1024, 1); FreeGB = [math]::Round([double]$parts[1] / 1024, 1) }
        }
    } catch {}

    $cpuCores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

    $result = [ordered]@{
        TotalMemGB    = $totalMemGB
        FreeMemGB     = $freeMemGB
        MemPctFree    = $memPctFree
        CpuCores      = $cpuCores
        GpuTotalGB    = if ($gpuInfo) { $gpuInfo.TotalGB } else { "N/A" }
        GpuFreeGB     = if ($gpuInfo) { $gpuInfo.FreeGB } else { "N/A" }
        MemOk         = $memPctFree -ge 20
        GpuOk         = if ($gpuInfo) { $gpuInfo.FreeGB -ge 4 } else { $true }
    }
    return $result
}

function Get-ModelSizingCeilingGB {
    # Fixed sizing logic: model ceiling is always system RAM (FreeMemGB), regardless of GPU presence.
    # GPU info is computed and logged as informational/speed context only.
    # Rationale: Ollama automatically offloads model layers that don't fit in VRAM to CPU/RAM,
    # so GPU only affects inference speed, not whether a model can run at all.
    # See: ADR-001-model-acquisition-placement.md decision point 3; backlog story 2.
    param(
        [Parameter(Mandatory)][object]$Resources
    )
    return $Resources.FreeMemGB
}

function Get-HuggingFaceGGUFCandidate {
    # Story 4b: query HF API for GGUF files, filter by size, return best candidate.
    # Called only when curated Ollama list has no fitting model.
    param(
        [Parameter(Mandatory)][double]$AvailableGB,
        [Parameter(Mandatory)][string]$LogFile
    )

    $hfBaseUrl = "https://huggingface.co/api/models?search=gguf&filter=gguf&sort=downloads&direction=-1&limit=5"
    try {
        $hfResults = Invoke-RestMethod -Uri $hfBaseUrl -TimeoutSec 10
        if (-not $hfResults -or $hfResults.Count -eq 0) {
            Write-AuditLog -Action "HuggingFaceAcquisition" -Result "WARNING" `
                -Message "Hugging Face search returned no results" -Detail "Endpoint: $hfBaseUrl"
            return $null
        }

        # Query each repo for GGUF file details.
        $bestCandidate = $null
        $bestSizeGB = 0

        foreach ($repo in $hfResults) {
            $repoId = $repo.id
            try {
                $repoInfoUrl = "https://huggingface.co/api/models/$repoId"
                $repoInfo = Invoke-RestMethod -Uri $repoInfoUrl -TimeoutSec 10

                # Find all .gguf files in siblings.
                $ggufFiles = $repoInfo.siblings | Where-Object { $_.rfilename -like "*.gguf" }
                foreach ($file in $ggufFiles) {
                    $sizeGB = $null
                    if ($file.size) {
                        $sizeGB = [math]::Round([double]$file.size / 1GB, 2)
                    } else {
                        # If size not in response, try HEAD request to get Content-Length.
                        try {
                            $headUrl = "https://huggingface.co/$repoId/resolve/main/$($file.rfilename)"
                            $headResp = Invoke-WebRequest -Uri $headUrl -Method Head -TimeoutSec 10
                            $contentLength = $headResp.Headers["Content-Length"]
                            if ($contentLength) {
                                $sizeGB = [math]::Round([double]$contentLength / 1GB, 2)
                            }
                        } catch {
                            # Skip file if size cannot be determined.
                            continue
                        }
                    }

                    # Check if fits (with 20% headroom).
                    if ($sizeGB -and ($AvailableGB -ge ($sizeGB * 1.2))) {
                        if ($sizeGB -gt $bestSizeGB) {
                            $bestSizeGB = $sizeGB
                            $bestCandidate = @{
                                RepoId   = $repoId
                                Filename = $file.rfilename
                                SizeGB   = $sizeGB
                                Url      = "https://huggingface.co/$repoId/resolve/main/$($file.rfilename)"
                            }
                        }
                    }
                }
            } catch {
                # Skip repo on error; continue to next.
                continue
            }
        }

        if ($bestCandidate) {
            Write-Host "  HuggingFace: Found candidate - $($bestCandidate.RepoId) ($($bestCandidate.SizeGB) GB)" -ForegroundColor Cyan
            Write-AuditLog -Action "HuggingFaceAcquisition" -Result "SUCCESS" `
                -Message "Found fitting HuggingFace GGUF: $($bestCandidate.RepoId) ($($bestCandidate.SizeGB) GB)" `
                -Detail "File: $($bestCandidate.Filename); URL: $($bestCandidate.Url)"
            return $bestCandidate
        } else {
            Write-AuditLog -Action "HuggingFaceAcquisition" -Result "WARNING" `
                -Message "No fitting GGUF file found in HuggingFace search results" `
                -Detail "Checked $($hfResults.Count) repos for files fitting $([math]::Round($AvailableGB, 1)) GB with headroom"
            return $null
        }
    } catch {
        Write-AuditLog -Action "HuggingFaceAcquisition" -Result "WARNING" `
            -Message "Hugging Face acquisition query failed" -Detail $_.Exception.Message
        return $null
    }
}

function Start-HuggingFaceImport {
    # Story 4b: download HF GGUF and import via `ollama create`.
    # Runs in background job; returns derived model name (e.g., hf-anthropic-qwen).
    param(
        [Parameter(Mandatory)][hashtable]$Candidate,
        [Parameter(Mandatory)][int]$LivePort,
        [Parameter(Mandatory)][string]$LogFile
    )

    # Derive model name: hf-<slugified-repo> (e.g., anthropic/qwen → hf-anthropic-qwen).
    $modelName = "hf-" + ($Candidate.RepoId -replace '/', '-' -replace '[^a-zA-Z0-9\-]', '')

    # ponytail: Start-Job only survives this PowerShell session. Upgrade path: detached process.
    $job = Start-Job -Name "HFImport-$modelName" -ArgumentList $Candidate, $modelName, $LivePort, $LogFile -ScriptBlock {
        param($Cand, $Model, $Port, $LogFile)

        function Write-JobAuditLog {
            param([string]$Action, [string]$Result, [string]$Message, [string]$Detail = "")
            $entry = [ordered]@{
                timestampUtc = [DateTime]::UtcNow.ToString("o")
                user         = $env:USERNAME
                host         = $env:COMPUTERNAME
                action       = $Action
                result       = $Result
                provider     = "huggingface"
                model        = $Model
                endpoint     = ""
                message      = $Message
                detail       = $Detail
            }
            ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
        }

        # Ensure download directory exists.
        $downloadDir = Join-Path $env:USERPROFILE ".ai-platform\models"
        if (-not (Test-Path $downloadDir)) {
            New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        }

        $safeFilename = (Split-Path -Leaf $Cand.Filename) -replace '[^a-zA-Z0-9._-]', ''
        $filepath = Join-Path $downloadDir $safeFilename

        try {
            # Download the GGUF file.
            Write-JobAuditLog -Action "HuggingFaceDownload" -Result "STARTED" `
                -Message "Downloading $($Cand.RepoId)/$($Cand.Filename) from HuggingFace" `
                -Detail "Size: $($Cand.SizeGB) GB"

            Invoke-WebRequest -Uri $Cand.Url -OutFile $filepath -TimeoutSec 3600 -ErrorAction Stop

            if ((Test-Path $filepath) -and ((Get-Item $filepath).Length -gt 0)) {
                Write-JobAuditLog -Action "HuggingFaceDownload" -Result "SUCCESS" `
                    -Message "Downloaded $($Cand.Filename) ($($Cand.SizeGB) GB)" `
                    -Detail "Saved to: $filepath"

                # Create Modelfile for `ollama create`.
                $modelfilePath = Join-Path $downloadDir "$Model.modelfile"
                "FROM $filepath" | Set-Content -Path $modelfilePath -Encoding utf8

                # Run `ollama create` to import the model.
                Write-JobAuditLog -Action "HuggingFaceImport" -Result "STARTED" `
                    -Message "Importing GGUF into Ollama: $Model"

                & ollama create $Model -f $modelfilePath
                Remove-Item -Path $modelfilePath -Force -ErrorAction SilentlyContinue
                if ($LASTEXITCODE -eq 0) {
                    Write-JobAuditLog -Action "HuggingFaceImport" -Result "SUCCESS" `
                        -Message "Model imported successfully: $Model"

                    # Auto-start: warm-start the model.
                    try {
                        $c = [System.Net.Http.HttpClient]::new()
                        $c.Timeout = [TimeSpan]::FromSeconds(120)
                        $body = [System.Net.Http.StringContent]::new(
                            (@{ model = $Model } | ConvertTo-Json -Compress),
                            [System.Text.Encoding]::UTF8, "application/json")
                        $warmResp = $c.PostAsync("http://127.0.0.1:$Port/api/generate", $body).Result
                        if ($warmResp.IsSuccessStatusCode) {
                            Write-JobAuditLog -Action "ModelStarted" -Result "SUCCESS" `
                                -Message "Model auto-started after HuggingFace import"
                        } else {
                            Write-JobAuditLog -Action "ModelStarted" -Result "WARNING" `
                                -Message "Warm-up call failed" -Detail "HTTP $($warmResp.StatusCode)"
                        }
                    } catch {
                        Write-JobAuditLog -Action "ModelStarted" -Result "WARNING" `
                            -Message "Warm-up call failed" -Detail $_.Exception.Message
                    }
                } else {
                    Write-JobAuditLog -Action "HuggingFaceImport" -Result "FAILED" `
                        -Message "ollama create failed for $Model"
                }
            } else {
                Remove-Item -Path $filepath -Force -ErrorAction SilentlyContinue
                Write-JobAuditLog -Action "HuggingFaceDownload" -Result "FAILED" `
                    -Message "Download failed or file is empty" -Detail "Path: $filepath"
            }
        } catch {
            Remove-Item -Path $filepath -Force -ErrorAction SilentlyContinue
            Write-JobAuditLog -Action "HuggingFaceDownload" -Result "FAILED" `
                -Message "Error downloading GGUF from HuggingFace" -Detail $_.Exception.Message
        }
    }

    Write-Host "  Starting HuggingFace import in background (job $($job.Id)) — won't block startup" -ForegroundColor Yellow
    Write-AuditLog -Action "HuggingFaceImport" -Result "STARTED" -ModelName $modelName `
        -Message "Importing $($Candidate.RepoId) in background (job $($job.Id)) — won't block startup"

    return $modelName
}

function Select-BestCuratedModel {
    # Pure: no I/O, no logging, no network. Extracted from Select-BestModel so
    # it's directly testable, same reason Get-ModelSizingCeilingGB was extracted.
    param(
        [Parameter(Mandatory)][double]$AvailableGB,
        [Parameter(Mandatory)][object]$ModelsConfig
    )
    $candidates = foreach ($candidate in $ModelsConfig.fallbackOrder) {
        $sizeGB = [double]($ModelsConfig.localModels.$candidate.size -replace '[^0-9.]', '')
        [pscustomobject]@{ Name = $candidate; SizeGB = $sizeGB; Fits = ($AvailableGB -ge ($sizeGB * 1.2)) }
    }
    $candidateSummary = ($candidates | ForEach-Object { "$($_.Name)=$($_.SizeGB)GB($(if ($_.Fits) {'fits'} else {'too big'}))" }) -join ", "
    # Prefer the largest model that still fits comfortably (with 20% headroom).
    $winner = $candidates | Where-Object { $_.Fits } | Sort-Object SizeGB -Descending | Select-Object -First 1
    [pscustomobject]@{
        Model   = if ($winner) { $winner.Name } else { $null }
        Summary = $candidateSummary
    }
}

function Select-BestModel {
    param(
        [Parameter(Mandatory)][double]$AvailableGB,
        [Parameter(Mandatory)][object]$Resources,
        [Parameter(Mandatory)][string]$GpuDesc,
        [Parameter(Mandatory)][string]$ScriptDir,
        [Parameter(Mandatory)][int]$LivePort
    )

    Write-Host ""
    Write-Host "Model discovery..." -ForegroundColor Yellow
    $modelsConfigPath = Join-Path $ScriptDir "..\config\models.json"
    $logFile = Join-Path $env:USERPROFILE ".ai-platform\logs\audit.jsonl"

    Get-ModelDiscoverySources -ConfigPath $modelsConfigPath -AvailableGB $AvailableGB

    $modelsConfigPath = Join-Path $ScriptDir "..\config\models.json"
    if (Test-Path $modelsConfigPath) {
        try {
            $modelsConfig = Get-Content $modelsConfigPath -Raw | ConvertFrom-Json
            $selection = Select-BestCuratedModel -AvailableGB $AvailableGB -ModelsConfig $modelsConfig
            $candidateSummary = $selection.Summary

            if ($selection.Model) {
                $Model = $selection.Model
                $reason = "largest model that fits in $([math]::Round($AvailableGB,1)) GB with headroom"
                Write-Host "  Auto-selected model: $Model (fits $([math]::Round($AvailableGB,1)) GB available)" -ForegroundColor Cyan
                Write-AuditLog -Action "ModelSelection" -Result "SUCCESS" -ModelName $Model `
                    -Message "$($Resources.TotalMemGB) GB RAM, $GpuDesc - selected $Model as the $reason" `
                    -Detail "Candidates: $candidateSummary"
            } else {
                # No curated model fits. Try HuggingFace.
                Write-Host "  No curated model fits; checking HuggingFace..." -ForegroundColor Yellow
                $hfCandidate = Get-HuggingFaceGGUFCandidate -AvailableGB $AvailableGB -LogFile $logFile

                if ($hfCandidate) {
                    $Model = Start-HuggingFaceImport -Candidate $hfCandidate -LivePort $LivePort -LogFile $logFile
                    Write-AuditLog -Action "ModelSelection" -Result "SUCCESS" -ModelName $Model `
                        -Message "Selected HuggingFace model $($hfCandidate.RepoId) ($($hfCandidate.SizeGB) GB) - importing in background" `
                        -Detail "Candidates (curated): $candidateSummary"
                } else {
                    # HF also has nothing; fall back to smallest curated model.
                    $Model = $modelsConfig.fallbackOrder[-1]
                    Write-Host "  WARNING: No model comfortably fits available hardware; falling back to smallest: $Model" -ForegroundColor Yellow
                    Write-AuditLog -Action "ModelSelection" -Result "WARNING" -ModelName $Model `
                        -Message "No candidate fit $([math]::Round($AvailableGB,1)) GB available; falling back to smallest model $Model" `
                        -Detail "Candidates (curated): $candidateSummary; HuggingFace: no fitting GGUF"
                }
            }
            return $Model
        } catch {
            Write-Host "  Could not read models.json for auto-selection; using default model" -ForegroundColor Yellow
            Write-AuditLog -Action "ModelSelection" -Result "WARNING" -Message "Could not read models.json for auto-selection; using default model" -Detail $_.Exception.Message
            return ""
        }
    }
    return ""
}

function Start-ModelAcquisitionPull {
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][int]$LivePort,
        [Parameter(Mandatory)][string]$LogFile
    )

    $modelPullPending = $false
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        $resp = $c.GetAsync("http://127.0.0.1:$LivePort/api/tags").Result
        $json = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
        $found = $json.models | Where-Object { $_.name -eq $Model }
        if ($found) {
            Write-Host "  Model '$Model' is ready" -ForegroundColor Green
            Write-Host "  Digest: $($found.digest)" -ForegroundColor DarkGray
            Write-Host "  Size  : $([math]::Round($found.size / 1GB, 2)) GB" -ForegroundColor DarkGray
            Write-AuditLog -Action "ModelCheck" -Result "SUCCESS" -ModelName $Model -Message "Model available" -Detail "Digest: $($found.digest)"
        } else {
            # Check if this is a HuggingFace-imported model (prefixed with "hf-").
            # HF models are imported via Start-HuggingFaceImport and don't exist in Ollama registry.
            if ($Model -like "hf-*") {
                Write-Host "  Model '$Model' (HuggingFace import) not ready yet; waiting for background import to complete..." -ForegroundColor Yellow
                Write-AuditLog -Action "ModelCheck" -Result "WARNING" -ModelName $Model `
                    -Message "HuggingFace model pending import; won't pull from Ollama registry (not available there)" `
                    -Detail "Check logs for HuggingFaceImport progress"
                $modelPullPending = $true
            } else {
                Write-Host "  Model '$Model' not found locally. Pulling it in the background..." -ForegroundColor Yellow

                # ponytail: Start-Job only survives this PowerShell session — closing the terminal
                # kills an in-progress pull. Upgrade path if that ever matters: a detached process
                # (Start-Process) instead of a session-bound job.
                $job = Start-Job -Name "ModelPull-$Model" -ArgumentList $Model, $LivePort, $LogFile -ScriptBlock {
                param($Model, $Port, $LogFile)

                function Write-JobAuditLog {
                    param(
                        [string]$Action,
                        [string]$Result,
                        [string]$Message,
                        [string]$Detail = ""
                    )
                    $entry = [ordered]@{
                        timestampUtc = [DateTime]::UtcNow.ToString("o")
                        user         = $env:USERNAME
                        host         = $env:COMPUTERNAME
                        action       = $Action
                        result       = $Result
                        provider     = "ollama"
                        model        = $Model
                        endpoint     = ""
                        message      = $Message
                        detail       = $Detail
                    }
                    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $LogFile -Encoding utf8
                }

                & ollama pull $Model
                if ($LASTEXITCODE -eq 0) {
                    Write-JobAuditLog -Action "ModelPull" -Result "SUCCESS" -Message "Model pulled in background"
                    try {
                        # Auto-start: a minimal /api/generate call (no prompt) makes Ollama load
                        # the model into memory without generating any tokens.
                        $c = [System.Net.Http.HttpClient]::new()
                        $c.Timeout = [TimeSpan]::FromSeconds(120)
                        $body = [System.Net.Http.StringContent]::new(
                            (@{ model = $Model } | ConvertTo-Json -Compress),
                            [System.Text.Encoding]::UTF8, "application/json")
                        $warmResp = $c.PostAsync("http://127.0.0.1:$Port/api/generate", $body).Result
                        if ($warmResp.IsSuccessStatusCode) {
                            Write-JobAuditLog -Action "ModelStarted" -Result "SUCCESS" -Message "Model auto-started after background pull"
                        } else {
                            Write-JobAuditLog -Action "ModelStarted" -Result "WARNING" -Message "Warm-up call failed" -Detail "HTTP $($warmResp.StatusCode)"
                        }
                    } catch {
                        Write-JobAuditLog -Action "ModelStarted" -Result "WARNING" -Message "Warm-up call failed" -Detail $_.Exception.Message
                    }
                } else {
                    Write-JobAuditLog -Action "ModelPull" -Result "FAILED" -Message "ollama pull failed"
                }
            }

                $modelPullPending = $true
                Write-Host "  Pulling '$Model' in the background (job $($job.Id)) — startup will continue without waiting" -ForegroundColor Yellow
                Write-AuditLog -Action "ModelPull" -Result "STARTED" -ModelName $Model -Message "Pulling '$Model' in the background (job $($job.Id)) — won't block startup"
            }
        }
    } catch {
        Write-Host "  Could not check models — Ollama may still be warming up" -ForegroundColor Yellow
    }

    return $modelPullPending
}
