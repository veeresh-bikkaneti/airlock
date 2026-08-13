# Self-check for ConvertFrom-OllamaPullLine in Get-ModelAcquisition.ps1 - the parser
# behind live download-progress reporting in ai-port/ai-health.
# Run: pwsh -File scripts/Test-PullProgress.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "Get-ModelAcquisition.ps1") *> $null

$failures = 0

$cases = @(
    @{
        name   = "mid-download line with speed and ETA"
        line   = "pulling 797b70c4edf8:  54% ▕█████████         ▏  24 MB/ 45 MB   22 MB/s      0s"
        expect = @{ Percent = 54; Downloaded = "24 MB"; Total = "45 MB"; Speed = "22 MB/s"; Eta = "0s" }
    }
    @{
        name   = "early line, no speed/ETA yet"
        line   = "pulling 797b70c4edf8:   2% ▕                  ▏ 894 KB/ 45 MB"
        expect = @{ Percent = 2; Downloaded = "894 KB"; Total = "45 MB"; Speed = $null; Eta = $null }
    }
    @{
        name   = "trailing clear-to-end-of-line code must not leak into ETA"
        line   = "pulling 797b70c4edf8:  97% ▕█████████████████ ▏  44 MB/ 45 MB   22 MB/s      0s[K"
        expect = @{ Percent = 97; Downloaded = "44 MB"; Total = "45 MB"; Speed = "22 MB/s"; Eta = "0s" }
    }
    @{
        name   = "unrelated line (manifest/digest) returns null, not a false match"
        line   = "verifying sha256 digest"
        expect = $null
    }
)

foreach ($c in $cases) {
    $result = ConvertFrom-OllamaPullLine -Line $c.line
    if ($null -eq $c.expect) {
        if ($null -ne $result) {
            Write-Host "FAIL: $($c.name) -> expected null, got $($result | ConvertTo-Json -Compress)" -ForegroundColor Red
            $failures++
        } else {
            Write-Host "PASS: $($c.name)" -ForegroundColor Green
        }
        continue
    }
    $mismatch = $result.Percent -ne $c.expect.Percent -or $result.Downloaded -ne $c.expect.Downloaded -or
        $result.Total -ne $c.expect.Total -or $result.Speed -ne $c.expect.Speed -or $result.Eta -ne $c.expect.Eta
    if ($mismatch) {
        Write-Host "FAIL: $($c.name) -> got $($result | ConvertTo-Json -Compress)" -ForegroundColor Red
        $failures++
    } else {
        Write-Host "PASS: $($c.name)" -ForegroundColor Green
    }
}

if ($failures -gt 0) { exit 1 }
Write-Host ""
Write-Host "All pull-progress checks passed" -ForegroundColor Green
