# Get-ModelAcquisition.ps1 — Model acquisition pipeline (discovery, sizing, selection, background pull)
# Called by scripts/Start-AI.ps1 after Write-AuditLog is defined
# Requires: Write-AuditLog (from Start-AI.ps1)

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

function Select-BestModel {
    param(
        [Parameter(Mandatory)][double]$AvailableGB,
        [Parameter(Mandatory)][object]$Resources,
        [Parameter(Mandatory)][string]$GpuDesc,
        [Parameter(Mandatory)][string]$ScriptDir
    )

    Write-Host ""
    Write-Host "Model discovery..." -ForegroundColor Yellow
    Get-ModelDiscoverySources -ConfigPath (Join-Path $ScriptDir "..\config\models.json") -AvailableGB $AvailableGB

    $modelsConfigPath = Join-Path $ScriptDir "..\config\models.json"
    if (Test-Path $modelsConfigPath) {
        try {
            $modelsConfig = Get-Content $modelsConfigPath -Raw | ConvertFrom-Json
            $candidates = foreach ($candidate in $modelsConfig.fallbackOrder) {
                $sizeGB = [double]($modelsConfig.localModels.$candidate.size -replace '[^0-9.]', '')
                [pscustomobject]@{ Name = $candidate; SizeGB = $sizeGB; Fits = ($AvailableGB -ge ($sizeGB * 1.2)) }
            }
            $candidateSummary = ($candidates | ForEach-Object { "$($_.Name)=$($_.SizeGB)GB($(if ($_.Fits) {'fits'} else {'too big'}))" }) -join ", "

            # Prefer the largest model that still fits comfortably (with 20% headroom).
            $winner = $candidates | Where-Object { $_.Fits } | Sort-Object SizeGB -Descending | Select-Object -First 1
            if ($winner) {
                $Model = $winner.Name
                $reason = "largest model that fits in $([math]::Round($AvailableGB,1)) GB with headroom"
                Write-Host "  Auto-selected model: $Model (fits $([math]::Round($AvailableGB,1)) GB available)" -ForegroundColor Cyan
                Write-AuditLog -Action "ModelSelection" -Result "SUCCESS" -ModelName $Model `
                    -Message "$($Resources.TotalMemGB) GB RAM, $GpuDesc - selected $Model as the $reason" `
                    -Detail "Candidates: $candidateSummary"
            } else {
                $Model = $modelsConfig.fallbackOrder[-1]
                Write-Host "  WARNING: No model comfortably fits available hardware; falling back to smallest: $Model" -ForegroundColor Yellow
                Write-AuditLog -Action "ModelSelection" -Result "WARNING" -ModelName $Model `
                    -Message "No candidate fit $([math]::Round($AvailableGB,1)) GB available; falling back to smallest model $Model" `
                    -Detail "Candidates: $candidateSummary"
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
    } catch {
        Write-Host "  Could not check models — Ollama may still be warming up" -ForegroundColor Yellow
    }

    return $modelPullPending
}
