# Self-check for agent-capability-registry.ps1 (ADR-012 Phase B, §5.2).
# Run: pwsh -File scripts/Test-AgentCapabilityRegistry.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "agent-capability-registry.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing agent-capability-registry.ps1..." -ForegroundColor Cyan

$now = [DateTime]::UtcNow

# --- Resolve-AirlockCapabilityCacheRead (pure) ---

$r1 = Resolve-AirlockCapabilityCacheRead -EntryExists $true -ExpiresAtUtc $now.AddMinutes(5) -NowUtc $now
Assert-True $r1.UseCache "fresh entry -> cache used"

$r2 = Resolve-AirlockCapabilityCacheRead -EntryExists $true -ExpiresAtUtc $now.AddMinutes(-1) -NowUtc $now
Assert-True (-not $r2.UseCache) "expired entry -> cache not used"

$r3 = Resolve-AirlockCapabilityCacheRead -EntryExists $false -NowUtc $now
Assert-True (-not $r3.UseCache) "no entry -> cache not used"

$r4 = Resolve-AirlockCapabilityCacheRead -EntryExists $true -ExpiresAtUtc $now.AddMinutes(5) -NowUtc $now -ForceVerify
Assert-True (-not $r4.UseCache) "-ForceVerify bypasses even a fresh cached entry"

$r5 = Resolve-AirlockCapabilityCacheRead -EntryExists $true -ExpiresAtUtc $now.AddMinutes(5) -NowUtc $now -NoCache
Assert-True (-not $r5.UseCache) "-NoCache bypasses even a fresh cached entry"

# --- Full read/write round trip (real I/O, isolated temp dir) ---

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-cap-registry-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $registryPath = Join-Path $workDir "capability-registry.json"
    $key = "sha256:test-evidence-key"

    $missing = Get-AirlockCapabilityEntry -EvidenceKey $key -RegistryPath $registryPath
    Assert-True (-not $missing.FromCache) "reading a non-existent registry returns no cached entry"

    $passWrite = Set-AirlockCapabilityEntry -EvidenceKey $key -RegistryPath $registryPath -Verdict 'pass' `
        -EntryData ([pscustomobject]@{ profileId = 'ollama-gemma4-12b' }) -PassTtlMinutes 5 -FailTtlMinutes 1
    Assert-True $passWrite.Written "a pass entry is written"

    $readBack = Get-AirlockCapabilityEntry -EvidenceKey $key -RegistryPath $registryPath
    Assert-True $readBack.FromCache "a freshly written pass entry is read back from cache"
    Assert-True ($readBack.Entry.verdict -eq 'pass') "the read-back entry's verdict is 'pass'"

    # Pass and failure entries have distinct TTLs: write a fail entry for a
    # different key with a very short TTL, prove it expires while the pass
    # entry (5 min TTL) is still fresh.
    $failKey = "sha256:test-evidence-key-fail"
    Set-AirlockCapabilityEntry -EvidenceKey $failKey -RegistryPath $registryPath -Verdict 'fail' `
        -EntryData ([pscustomobject]@{ profileId = 'ollama-gemma4-12b' }) -PassTtlMinutes 5 -FailTtlMinutes 0 | Out-Null
    Start-Sleep -Milliseconds 50
    $failReadBack = Get-AirlockCapabilityEntry -EvidenceKey $failKey -RegistryPath $registryPath
    Assert-True (-not $failReadBack.FromCache) "a fail entry with a 0-minute TTL is already expired on the next read"
    $passStillFresh = Get-AirlockCapabilityEntry -EvidenceKey $key -RegistryPath $registryPath
    Assert-True $passStillFresh.FromCache "the pass entry (5-minute TTL) is unaffected by the fail entry's shorter TTL - each entry's TTL is independent"

    # -NoCache never reads or writes.
    $beforeHash = (Get-FileHash $registryPath -Algorithm SHA256).Hash
    $noCacheRead = Get-AirlockCapabilityEntry -EvidenceKey $key -RegistryPath $registryPath -NoCache
    Assert-True (-not $noCacheRead.FromCache) "-NoCache never reads an existing entry"
    $noCacheWrite = Set-AirlockCapabilityEntry -EvidenceKey $key -RegistryPath $registryPath -Verdict 'pass' `
        -EntryData ([pscustomobject]@{ profileId = 'should-not-be-written' }) -PassTtlMinutes 5 -FailTtlMinutes 1 -NoCache
    Assert-True (-not $noCacheWrite.Written) "-NoCache never writes"
    Assert-True ((Get-FileHash $registryPath -Algorithm SHA256).Hash -eq $beforeHash) "-NoCache leaves the registry file byte-for-byte unchanged"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures agent-capability-registry check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All agent-capability-registry checks passed" -ForegroundColor Green
exit 0
