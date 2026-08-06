# Self-check for the pure vLLM-viability decision logic in Get-BackendCapability.ps1.
# Run: pwsh -File scripts/Test-BackendCapability.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "Get-BackendCapability.ps1")

$cases = @(
    @{ name = "GPU + Docker -> viable"; gpu = $true; docker = $true; expect = $true }
    @{ name = "GPU only, no Docker -> not viable"; gpu = $true; docker = $false; expect = $false }
    @{ name = "Docker only, no GPU -> not viable"; gpu = $false; docker = $true; expect = $false }
    @{ name = "Neither -> not viable"; gpu = $false; docker = $false; expect = $false }
)

$failures = 0
foreach ($c in $cases) {
    $result = Test-VLLMViable -HasNvidiaGpu $c.gpu -DockerRunning $c.docker
    if ($result -ne $c.expect) {
        Write-Host "FAIL: $($c.name) -> got $result, expected $($c.expect)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($c.name)" -ForegroundColor Green
    }
}

if ($failures -gt 0) {
    Write-Host "$failures test(s) failed." -ForegroundColor Red
    exit 1
} else {
    Write-Host "All tests passed." -ForegroundColor Green
    exit 0
}
