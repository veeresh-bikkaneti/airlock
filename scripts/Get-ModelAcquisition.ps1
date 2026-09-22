# Get-ModelAcquisition.ps1 — Model acquisition pipeline (discovery, sizing, selection, background pull)
# Called by scripts/Start-AI.ps1 after Write-AuditLog is defined
# Requires: Write-AuditLog (from Start-AI.ps1)

$script:AcquisitionScriptDir = $PSScriptRoot

# Cold-machine fix: storage preflight for multi-GB downloads. Guarded so
# this file still dot-sources cleanly in tests that stub the helper.
if (-not (Get-Command Test-StoragePreflight -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "StoragePreflight.ps1")
}

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
    # Sizing ceiling is free VRAM when a GPU is present, else free system RAM.
    # Rationale: a model that spills to CPU still "runs" but is unusably slow for an
    # interactive agentic loop - GPU fit, not RAM fit, determines whether the result
    # is actually usable. See ADR-005-model-sizing-against-vram.md (supersedes
    # ADR-001 decision point 3 - this used to be RAM-only on purpose; see that ADR
    # for why it changed).
    param(
        [Parameter(Mandatory)][object]$Resources
    )
    if ($Resources.GpuTotalGB -ne "N/A") {
        return $Resources.GpuFreeGB
    }
    return $Resources.FreeMemGB
}

function Get-InstalledModelNames {
    # Best-effort list of models already pulled into the running Ollama instance.
    # Never blocks selection on failure - an empty list just means no installed-model
    # preference kicks in, falling back to plain size-based selection.
    param([Parameter(Mandatory)][int]$LivePort)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        $resp = $c.GetAsync("http://127.0.0.1:$LivePort/api/tags").Result
        $json = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json
        return @($json.models | ForEach-Object { $_.name })
    } catch {
        return @()
    }
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

function Get-ModelPullRecord {
    $path = Join-Path $env:USERPROFILE ".ai-platform\state\model-pull.json"
    if (-not (Test-Path $path)) { return $null }
    try {
        return Get-Content $path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-ModelPullStatus {
    $st = Get-ModelPullRecord
    if (-not $st) { return $null }
    if (-not $st.pid -or [int]$st.pid -le 0) { return $null }
    if (-not (Get-Process -Id $st.pid -ErrorAction SilentlyContinue)) { return $null }
    return $st
}

# Story 4c: a dead worker that recorded lastResult=FAILED for this model
# means "do not keep saying pending" — caller should fall back.
function Resolve-AirlockFailedPullFallback {
    param(
        [AllowNull()]$Record,
        [Parameter(Mandatory)][string]$RequestedModel,
        [Parameter(Mandatory)][string]$FallbackModel
    )
    if (-not $Record) {
        return [pscustomobject]@{ Action = 'none'; Model = $RequestedModel; Reason = 'no pull record' }
    }
    $last = [string]$Record.lastResult
    $recorded = [string]$Record.model
    $pidLive = $false
    if ($Record.pid -and [int]$Record.pid -gt 0) {
        $pidLive = [bool](Get-Process -Id ([int]$Record.pid) -ErrorAction SilentlyContinue)
    }
    if ($pidLive) {
        return [pscustomobject]@{ Action = 'none'; Model = $RequestedModel; Reason = 'pull still running' }
    }
    if ($last -eq 'FAILED' -and $recorded -eq $RequestedModel) {
        if ($FallbackModel -eq $RequestedModel) {
            return [pscustomobject]@{
                Action = 'give-up'
                Model  = $RequestedModel
                Reason = "detached pull of '$RequestedModel' already failed; not starting the same worker again"
            }
        }
        return [pscustomobject]@{
            Action = 'fallback'
            Model  = $FallbackModel
            Reason = "detached pull of '$RequestedModel' failed; falling back to '$FallbackModel'"
        }
    }
    return [pscustomobject]@{ Action = 'none'; Model = $RequestedModel; Reason = 'no failed pull to recover' }
}

function Save-ModelPullState {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Kind
    )
    $dir = Join-Path $env:USERPROFILE ".ai-platform\state"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ([ordered]@{
        pid       = $ProcessId
        model     = $Model
        startedAt = [DateTime]::UtcNow.ToString("o")
        kind      = $Kind
    } | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $dir "model-pull.json") -Encoding utf8NoBOM
}

# Pure: one in-flight pull at a time. Reuse only when the live pid is already
# fetching this exact model; otherwise refuse so callers never log STARTED /
# SUCCESS for model B while pid is pulling model A.
function Resolve-AirlockInFlightPull {
    param(
        [AllowNull()]$Existing,
        [Parameter(Mandatory)][string]$RequestedModel
    )
    if (-not $Existing) {
        return [pscustomobject]@{ Action = 'start'; Reason = 'no in-flight pull' }
    }
    $existingModel = [string]$Existing.model
    if ($existingModel -eq $RequestedModel) {
        return [pscustomobject]@{
            Action = 'reuse'
            Reason = "reuse in-flight pull pid $($Existing.pid) for $RequestedModel"
        }
    }
    return [pscustomobject]@{
        Action = 'refuse'
        Reason = "in-flight pull pid $($Existing.pid) is '$existingModel'; not starting '$RequestedModel'"
    }
}

function Start-HuggingFaceImport {
    # Story 4b: download HF GGUF and import via `ollama create`.
    # Detached process; returns derived model name (e.g., hf-anthropic-qwen).
    param(
        [Parameter(Mandatory)][hashtable]$Candidate,
        [Parameter(Mandatory)][int]$LivePort,
        [Parameter(Mandatory)][string]$LogFile
    )

    $modelName = "hf-" + ($Candidate.RepoId -replace '/', '-' -replace '[^a-zA-Z0-9\-]', '')

    $existing = Get-ModelPullStatus
    $gate = Resolve-AirlockInFlightPull -Existing $existing -RequestedModel $modelName
    if ($gate.Action -eq 'reuse') {
        Write-Host "  HuggingFace import already running (pid $($existing.pid), $($existing.model)); reusing." -ForegroundColor Yellow
        return $modelName
    }
    if ($gate.Action -eq 'refuse') {
        Write-Host "  FAILED: $($gate.Reason). Wait for that pull to finish before starting another." -ForegroundColor Red
        Write-AuditLog -Action "HuggingFaceImport" -Result "FAILED" -ModelName $modelName -Message $gate.Reason
        return $null
    }

    # Cold-machine fix: refuse BEFORE the multi-GB GGUF download when the
    # disk can't hold it, instead of failing mid-download.
    $hfStorage = Test-StoragePreflight -RequiredGB ([double]$Candidate.SizeGB * 1.5) -Path (Join-Path $env:USERPROFILE ".ai-platform\models")
    if (-not $hfStorage.Ok) {
        Write-Host "  FAILED: $($hfStorage.Reason)" -ForegroundColor Red
        Write-AuditLog -Action "HuggingFaceImport" -Result "FAILED" -ModelName $modelName -Message $hfStorage.Reason
        return $null
    }

    $puller = Join-Path $script:AcquisitionScriptDir "Invoke-DetachedModelPull.ps1"
    $argList = @(
        '-NoProfile', '-File', $puller,
        '-Kind', 'import',
        '-Model', $modelName,
        '-Port', "$LivePort",
        '-LogFile', $LogFile,
        '-RepoId', "$($Candidate.RepoId)",
        '-Filename', "$($Candidate.Filename)",
        '-Url', "$($Candidate.Url)",
        '-SizeGB', "$($Candidate.SizeGB)"
    )
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList $argList -WindowStyle Hidden -PassThru
    Save-ModelPullState -ProcessId $proc.Id -Model $modelName -Kind 'hf-import'

    Write-Host "  Starting HuggingFace import in background (pid $($proc.Id)) — won't block startup" -ForegroundColor Yellow
    Write-AuditLog -Action "HuggingFaceImport" -Result "STARTED" -ModelName $modelName `
        -Message "Importing $($Candidate.RepoId) in background (pid $($proc.Id)) — won't block startup"

    return $modelName
}

function Select-BestCuratedModel {
    # Pure: no I/O, no logging, no network. Extracted from Select-BestModel so
    # it's directly testable, same reason Get-ModelSizingCeilingGB was extracted.
    param(
        [Parameter(Mandatory)][double]$AvailableGB,
        [Parameter(Mandatory)][object]$ModelsConfig,
        [string[]]$InstalledModels = @()
    )
    $candidates = foreach ($candidate in $ModelsConfig.fallbackOrder) {
        $sizeGB = [double]($ModelsConfig.localModels.$candidate.size -replace '[^0-9.]', '')
        $verdict = $ModelsConfig.localModels.$candidate.agenticLoopVerdict
        if (-not $verdict) { $verdict = 'unproven' }
        $verdict = $verdict.ToString().ToLowerInvariant()
        [pscustomobject]@{
            Name              = $candidate
            SizeGB            = $sizeGB
            Fits              = ($AvailableGB -ge ($sizeGB * 1.2))
            Installed         = $InstalledModels -contains $candidate
            ReliabilityNote   = $ModelsConfig.localModels.$candidate.agenticReliabilityNote
            AgenticRank       = if ($verdict -eq 'fail') { 0 } else { 1 }
        }
    }
    $candidateSummary = ($candidates | ForEach-Object {
        "$($_.Name)=$($_.SizeGB)GB($(if ($_.Fits) {'fits'} else {'too big'}))$(if ($_.Installed) {'[installed]'} else {''})"
    }) -join ", "
    # Fit first. Known-failed agentic loops lose to unproven/pass (AGENT-001).
    # Then already-pulled over a same-class download, then largest.
    $fitting = $candidates | Where-Object { $_.Fits }
    $winner = $fitting |
        Sort-Object -Property @{Expression = 'AgenticRank'; Descending = $true }, @{Expression = 'Installed'; Descending = $true }, @{Expression = 'SizeGB'; Descending = $true } |
        Select-Object -First 1
    $reason = if (-not $winner) {
        "largest model that fits with headroom"
    } elseif ($winner.AgenticRank -eq 0) {
        "known-failed agentic model (only class that fits)"
    } elseif ($fitting | Where-Object { $_.AgenticRank -eq 0 }) {
        "skipped known-failed agentic models"
    } elseif ($winner.Installed -and ($fitting | Where-Object { $_.SizeGB -gt $winner.SizeGB })) {
        "already installed - preferred over a larger download that also fit"
    } else {
        "largest model that fits with headroom"
    }
    [pscustomobject]@{
        Model           = if ($winner) { $winner.Name } else { $null }
        Summary         = $candidateSummary
        Reason          = $reason
        ReliabilityNote = if ($winner) { $winner.ReliabilityNote } else { $null }
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
            $installedModels = Get-InstalledModelNames -LivePort $LivePort
            $selection = Select-BestCuratedModel -AvailableGB $AvailableGB -ModelsConfig $modelsConfig -InstalledModels $installedModels
            $candidateSummary = $selection.Summary

            if ($selection.Model) {
                $Model = $selection.Model
                $reason = "$($selection.Reason) (ceiling: $([math]::Round($AvailableGB,1)) GB)"
                Write-Host "  Auto-selected model: $Model (fits $([math]::Round($AvailableGB,1)) GB available)" -ForegroundColor Cyan
                if ($selection.ReliabilityNote) {
                    Write-Host "  WARNING (agentic reliability): $($selection.ReliabilityNote)" -ForegroundColor Yellow
                }
                Write-AuditLog -Action "ModelSelection" -Result $(if ($selection.ReliabilityNote) { "WARNING" } else { "SUCCESS" }) -ModelName $Model `
                    -Message "$($Resources.TotalMemGB) GB RAM, $GpuDesc - selected $Model as the $reason" `
                    -Detail "Candidates: $candidateSummary$(if ($selection.ReliabilityNote) { "; Agentic reliability note: $($selection.ReliabilityNote)" })"
            } else {
                # No curated model fits. Try HuggingFace.
                Write-Host "  No curated model fits; checking HuggingFace..." -ForegroundColor Yellow
                $hfCandidate = Get-HuggingFaceGGUFCandidate -AvailableGB $AvailableGB -LogFile $logFile

                if ($hfCandidate) {
                    $Model = Start-HuggingFaceImport -Candidate $hfCandidate -LivePort $LivePort -LogFile $logFile
                    if ($Model) {
                        Write-AuditLog -Action "ModelSelection" -Result "SUCCESS" -ModelName $Model `
                            -Message "Selected HuggingFace model $($hfCandidate.RepoId) ($($hfCandidate.SizeGB) GB) - importing in background" `
                            -Detail "Candidates (curated): $candidateSummary"
                    } else {
                        $Model = $modelsConfig.fallbackOrder[-1]
                        Write-Host "  WARNING: HuggingFace import not started (another pull is in flight); falling back to smallest: $Model" -ForegroundColor Yellow
                        Write-AuditLog -Action "ModelSelection" -Result "WARNING" -ModelName $Model `
                            -Message "HuggingFace import refused because another pull is in flight; falling back to smallest model $Model" `
                            -Detail "Candidates (curated): $candidateSummary"
                    }
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

function ConvertFrom-OllamaPullLine {
    # Pure: no I/O. `ollama pull` never falls back to plain newline output even when
    # redirected - it always emits cursor-control codes - but PowerShell's pipeline still
    # splits it into discrete strings this can regex, one screen-update per line.
    # Returns $null for lines that aren't a progress update (manifest/digest/etc lines).
    param([Parameter(Mandatory)][string]$Line)
    # ETA capture is deliberately \d+[a-zA-Z]+ (e.g. "42s", "3m") rather than \S+ - ollama's
    # line has no space before the trailing [K clear-to-end-of-line code in this position,
    # so a greedy \S+ would swallow "0s[K" instead of stopping at "0s".
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

function Start-ModelAcquisitionPull {
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][int]$LivePort,
        [Parameter(Mandatory)][string]$LogFile,
        [string]$FallbackModel
    )

    $script:AirlockEffectiveChatModel = $Model
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
            if ($FallbackModel) {
                $fb = Resolve-AirlockFailedPullFallback -Record (Get-ModelPullRecord) -RequestedModel $Model -FallbackModel $FallbackModel
                if ($fb.Action -eq 'give-up') {
                    Write-Host "  $($fb.Reason)" -ForegroundColor Red
                    Write-AuditLog -Action "ModelPull" -Result "FAILED" -ModelName $Model -Message $fb.Reason
                    return $false
                }
                if ($fb.Action -eq 'fallback') {
                    Write-Host "  $($fb.Reason)" -ForegroundColor Yellow
                    Write-AuditLog -Action "ModelPull" -Result "WARNING" -ModelName $fb.Model -Message $fb.Reason
                    $Model = $fb.Model
                    $script:AirlockEffectiveChatModel = $Model
                    $found = $json.models | Where-Object { $_.name -eq $Model }
                    if ($found) {
                        Write-Host "  Fallback model '$Model' is ready" -ForegroundColor Green
                        Write-AuditLog -Action "ModelCheck" -Result "SUCCESS" -ModelName $Model -Message "Fallback model available after failed pull"
                        return $false
                    }
                }
            }
            # Check if this is a HuggingFace-imported model (prefixed with "hf-").
            # HF models are imported via Start-HuggingFaceImport and don't exist in Ollama registry.
            if ($Model -like "hf-*") {
                Write-Host "  Model '$Model' (HuggingFace import) not ready yet; waiting for background import to complete..." -ForegroundColor Yellow
                Write-AuditLog -Action "ModelCheck" -Result "WARNING" -ModelName $Model `
                    -Message "HuggingFace model pending import; won't pull from Ollama registry (not available there)" `
                    -Detail "Check logs for HuggingFaceImport progress"
                $modelPullPending = $true
            } else {
                Write-Host "  Model '$Model' not found locally." -ForegroundColor Yellow

                $existing = Get-ModelPullStatus
                $gate = Resolve-AirlockInFlightPull -Existing $existing -RequestedModel $Model
                if ($gate.Action -eq 'reuse') {
                    Write-Host "  Pull already running (pid $($existing.pid), $($existing.model)); reusing." -ForegroundColor Yellow
                    Write-Host "  Progress: run ai-port or ai-health to see it — no need to wait here." -ForegroundColor Yellow
                    Write-AuditLog -Action "ModelPull" -Result "STARTED" -ModelName $Model -Message $gate.Reason
                    $modelPullPending = $true
                } elseif ($gate.Action -eq 'refuse') {
                    Write-Host "  FAILED: $($gate.Reason). Wait for that pull to finish before starting another." -ForegroundColor Red
                    Write-AuditLog -Action "ModelPull" -Result "FAILED" -ModelName $Model -Message $gate.Reason
                } else {
                    # Cold-machine fix: storage preflight BEFORE the pull
                    # starts. A nearly-full disk used to produce a failed
                    # download and a stranded "pending" model; now it fails
                    # fast with a clear reason and nothing is downloaded.
                    $pullRequiredGB = 5.0  # fallback when the model isn't in the curated catalogue
                    try {
                        $pullCfgPath = Join-Path $script:AcquisitionScriptDir "..\config\models.json"
                        $pullCfg = Get-Content $pullCfgPath -Raw | ConvertFrom-Json
                        if ($pullCfg.localModels.$Model.size -match '([0-9.]+)\s*(GB|MB)') {
                            $sizeNum = [double]$Matches[1]
                            if ($Matches[2] -eq 'MB') { $sizeNum = $sizeNum / 1024 }
                            # 1.5x: download temp + final blob.
                            $pullRequiredGB = $sizeNum * 1.5
                        }
                    } catch {}
                    $pullStorage = Test-StoragePreflight -RequiredGB $pullRequiredGB -Path (Join-Path $env:USERPROFILE ".ai-platform")
                    if (-not $pullStorage.Ok) {
                        Write-Host "  FAILED: $($pullStorage.Reason)" -ForegroundColor Red
                        Write-Host "  Free up disk space, then re-run ai-start." -ForegroundColor Yellow
                        Write-AuditLog -Action "ModelPull" -Result "FAILED" -ModelName $Model -Message $pullStorage.Reason
                        return $false
                    }
                    Write-Host "  Progress: run ai-port or ai-health to see it — no need to wait here." -ForegroundColor Yellow
                    $progressFile = "$env:USERPROFILE\.ai-platform\.pull-progress.json"
                    $puller = Join-Path $script:AcquisitionScriptDir "Invoke-DetachedModelPull.ps1"
                    $argList = @(
                        '-NoProfile', '-File', $puller,
                        '-Kind', 'pull',
                        '-Model', $Model,
                        '-Port', "$LivePort",
                        '-LogFile', $LogFile,
                        '-ProgressFile', $progressFile
                    )
                    $proc = Start-Process -FilePath 'pwsh' -ArgumentList $argList -WindowStyle Hidden -PassThru
                    Save-ModelPullState -ProcessId $proc.Id -Model $Model -Kind 'ollama-pull'
                    $modelPullPending = $true
                    Write-Host "  Pulling '$Model' in the background (pid $($proc.Id)) — startup will continue without waiting" -ForegroundColor Yellow
                    Write-AuditLog -Action "ModelPull" -Result "STARTED" -ModelName $Model -Message "Pulling '$Model' in the background (pid $($proc.Id)) — won't block startup"
                }
            }
        }
    } catch {
        Write-Host "  Could not check models — Ollama may still be warming up" -ForegroundColor Yellow
    }

    return $modelPullPending
}
