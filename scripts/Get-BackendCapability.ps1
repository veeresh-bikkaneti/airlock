function Test-VLLMViable {
    # Pure decision function, no I/O — kept separate from Get-BackendCapability
    # so it's testable without real hardware. See Test-BackendCapability.ps1.
    param(
        [Parameter(Mandatory)][bool]$HasNvidiaGpu,
        [Parameter(Mandatory)][bool]$DockerRunning
    )
    return ($HasNvidiaGpu -and $DockerRunning)
}

function Get-BackendCapability {
    # Cheap, fast signals only. The real verifier is Start-VLLM.ps1's health
    # check — if GPU passthrough into the container doesn't work despite these
    # signals looking good, that check catches it and falls back to Ollama
    # (see Start-AI.ps1's handoff/fallback logic).
    $hasNvidiaGpu = $false
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Out-Null
            $hasNvidiaGpu = ($LASTEXITCODE -eq 0)
        } catch { $hasNvidiaGpu = $false }
    }

    $dockerRunning = $false
    try {
        docker info 2>$null | Out-Null
        $dockerRunning = ($LASTEXITCODE -eq 0)
    } catch { $dockerRunning = $false }

    [pscustomobject]@{
        HasNvidiaGpu   = $hasNvidiaGpu
        DockerRunning  = $dockerRunning
        VLLMViable     = (Test-VLLMViable -HasNvidiaGpu $hasNvidiaGpu -DockerRunning $dockerRunning)
    }
}
