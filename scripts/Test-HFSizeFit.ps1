# Test-HFSizeFit.ps1 — verify size-fit logic for HuggingFace GGUF files
# Converts bytes to GB and applies 20% headroom rule (same logic as in Get-HuggingFaceGGUFCandidate)

$testCases = @(
    @{ SizeBytes = 4294967296; AvailableGB = 10; ShouldFit = $true; Desc = "4GB file, 10GB available (fits with 20% headroom)" }
    @{ SizeBytes = 4294967296; AvailableGB = 4; ShouldFit = $false; Desc = "4GB file, 4GB available (no headroom)" }
    @{ SizeBytes = 7516192768; AvailableGB = 9; ShouldFit = $true; Desc = "7GB file, 9GB available (fits)" }
    @{ SizeBytes = 10737418240; AvailableGB = 12; ShouldFit = $true; Desc = "10GB file, 12GB available (fits)" }
    @{ SizeBytes = 10737418240; AvailableGB = 11; ShouldFit = $false; Desc = "10GB file, 11GB available (no headroom)" }
    # Edge cases: exact boundary and fractional boundary
    @{ SizeBytes = 10737418240; AvailableGB = 12.0; ShouldFit = $true; Desc = "10GB file, 12.0GB available (exact 1.2x boundary, should fit)" }
    @{ SizeBytes = 10737418240; AvailableGB = 11.99; ShouldFit = $false; Desc = "10GB file, 11.99GB available (just under 1.2x boundary, should not fit)" }
    @{ SizeBytes = 10737418240; AvailableGB = 12.001; ShouldFit = $true; Desc = "10GB file, 12.001GB available (just over 1.2x boundary, should fit)" }
    @{ SizeBytes = 1073741824; AvailableGB = 1.2; ShouldFit = $true; Desc = "1GB file, 1.2GB available (exact boundary for 1GB)" }
    @{ SizeBytes = 1073741824; AvailableGB = 1.19; ShouldFit = $false; Desc = "1GB file, 1.19GB available (just under boundary for 1GB)" }
    # Very small file edge case
    @{ SizeBytes = 104857600; AvailableGB = 1; ShouldFit = $true; Desc = "100MB file, 1GB available (very small, always fits)" }
    @{ SizeBytes = 104857600; AvailableGB = 0.2; ShouldFit = $true; Desc = "100MB file, 0.2GB available (very small with headroom)" }
)

$allPass = $true
foreach ($test in $testCases) {
    $sizeGB = [math]::Round([double]$test.SizeBytes / 1GB, 2)
    $fits = $test.AvailableGB -ge ($sizeGB * 1.2)
    $pass = $fits -eq $test.ShouldFit
    $allPass = $allPass -and $pass
    $status = if ($pass) { "PASS" } else { "FAIL" }
    Write-Host "$($status): $($test.Desc) - Size: $sizeGB GB, Fits: $fits"
}

if ($allPass) {
    Write-Host ""
    Write-Host "All size-fit checks passed" -ForegroundColor Green
    exit 0
} else {
    Write-Host ""
    Write-Host "Some checks failed" -ForegroundColor Red
    exit 1
}
