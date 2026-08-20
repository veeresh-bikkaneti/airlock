# Self-check for agent-state-helpers.ps1 (ADR-012 Phase A).
# Run: pwsh -File scripts/Test-AgentStateHelpers.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "agent-state-helpers.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) {
        Write-Host "PASS: $Message" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $Message" -ForegroundColor Red
        $script:failures++
    }
}

Write-Host "Testing agent-state-helpers.ps1..." -ForegroundColor Cyan

# --- Resolve-LockTakeover (pure decision logic) ---

$d1 = Resolve-LockTakeover -LockExists $false
Assert-True $d1.Allowed "no existing lock -> takeover allowed"

$d2 = Resolve-LockTakeover -LockExists $true -OwnerAlive $true
Assert-True (-not $d2.Allowed) "lock held by a live owner, no -ForceRecover -> refused"

$d3 = Resolve-LockTakeover -LockExists $true -OwnerAlive $true -ForceRecover
Assert-True (-not $d3.Allowed) "lock held by a live owner, -ForceRecover -> still refused (never override a live owner)"

$d4 = Resolve-LockTakeover -LockExists $true -OwnerAlive $false
Assert-True $d4.Allowed "lock owner is dead/stale -> takeover allowed"

# --- New-AirlockLock / Remove-AirlockLock (real I/O, isolated temp dir) ---

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-state-helpers-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $lockPath = Join-Path $workDir "test.lock"

    $lock1 = New-AirlockLock -LockPath $lockPath
    Assert-True (Test-Path $lockPath) "New-AirlockLock creates the lock file"
    Assert-True ($lock1.ownerPid -eq $PID) "lock record's ownerPid is this process"

    try {
        New-AirlockLock -LockPath $lockPath | Out-Null
        Assert-True $false "second concurrent lock attempt should have thrown"
    } catch {
        Assert-True $true "concurrent lock attempt while owner is alive throws"
    }

    try {
        Remove-AirlockLock -LockPath $lockPath -SessionId ([guid]::NewGuid().ToString())
        Assert-True $false "releasing with the wrong session id should have thrown"
    } catch {
        Assert-True $true "releasing with the wrong session id throws (never release someone else's lock)"
    }

    Remove-AirlockLock -LockPath $lockPath -SessionId $lock1.sessionId
    Assert-True (-not (Test-Path $lockPath)) "releasing with the correct session id removes the lock file"

    # Stale lock: pid 999999999 should not resolve to a real live process.
    $staleLock = [ordered]@{ sessionId = [guid]::NewGuid().ToString(); ownerPid = 999999999; ownerStartTimeTicks = [DateTime]::UtcNow.Ticks; acquiredAt = [DateTime]::UtcNow.ToString('o') }
    Write-AirlockAtomicJson -Path $lockPath -Data $staleLock
    $lock2 = New-AirlockLock -LockPath $lockPath
    Assert-True ($lock2.sessionId -ne $staleLock.sessionId) "a lock whose owner PID is dead is safely taken over, not blocked"
    Remove-AirlockLock -LockPath $lockPath -SessionId $lock2.sessionId

    # --- Write-AirlockAtomicJson: no temp file left behind, overwrite works ---
    $jsonPath = Join-Path $workDir "state.json"
    Write-AirlockAtomicJson -Path $jsonPath -Data @{ a = 1 }
    $leftoverTemp = Get-ChildItem -Path $workDir -Filter ".*.tmp" -Force -ErrorAction SilentlyContinue
    Assert-True ($leftoverTemp.Count -eq 0) "atomic write leaves no .tmp file behind"
    Assert-True ((Get-Content $jsonPath -Raw | ConvertFrom-Json).a -eq 1) "atomic write produced valid, readable JSON"

    Write-AirlockAtomicJson -Path $jsonPath -Data @{ a = 2 }
    Assert-True ((Get-Content $jsonPath -Raw | ConvertFrom-Json).a -eq 2) "atomic write overwrites an existing file"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Get-AirlockCapabilityEvidenceKey: every component must move the hash ---

$baseline = [ordered]@{
    ContractVersion       = "1"
    ProfileId             = "ollama-gemma4-12b"
    ModelRef              = "gemma4:12b"
    ModelDigest           = "sha256:aaa"
    ArtifactHash          = "sha256:bbb"
    Runtime               = "ollama"
    RuntimeVersion        = "0.5.0"
    EndpointMode          = "ollama-openai-direct"
    EndpointIdentity      = "http://127.0.0.1:12345/v1"
    RuntimeConfigHash     = "sha256:ccc"
    ChatTemplateIdentity  = "gemma4-default"
    EffectiveContext      = "8192"
    KvCacheMode           = "f16"
    Harness               = "opencode"
    HarnessVersion        = "1.2.3"
    HarnessConfigHash     = "sha256:ddd"
    ToolSurfaceHash       = "sha256:eee"
    SandboxPolicyVersion  = "1"
    ProxyVersion          = "sha256:fff"
}

$baseKey = Get-AirlockCapabilityEvidenceKey @baseline
Assert-True ($baseKey -like "sha256:*") "evidence key is a sha256: prefixed hash"

foreach ($name in $baseline.Keys) {
    $mutated = [ordered]@{}
    foreach ($k in $baseline.Keys) { $mutated[$k] = $baseline[$k] }
    $mutated[$name] = "$($baseline[$name])-mutated"
    $mutatedKey = Get-AirlockCapabilityEvidenceKey @mutated
    Assert-True ($mutatedKey -ne $baseKey) "changing '$name' alone changes the evidence key"
}

$repeatKey = Get-AirlockCapabilityEvidenceKey @baseline
Assert-True ($repeatKey -eq $baseKey) "evidence key is deterministic for identical components"

# --- Publish-AirlockActiveAgentCertificate: success-only atomic replace (I-03) ---

$certWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-cert-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $certWorkDir -ItemType Directory -Force | Out-Null
try {
    $certPath = Join-Path $certWorkDir "active-agent.json"
    $priorCert = @{ profileId = "prior-profile"; sessionId = "prior-session" }
    Write-AirlockAtomicJson -Path $certPath -Data $priorCert

    $failedResult = Publish-AirlockActiveAgentCertificate -CertificatePath $certPath -Certificate @{ profileId = "new-profile" } -ContractPassed $false
    Assert-True (-not $failedResult.Published) "Publish reports not-published when ContractPassed is false"
    $onDisk = Get-Content $certPath -Raw | ConvertFrom-Json
    Assert-True ($onDisk.profileId -eq "prior-profile") "a failed contract never mutates the prior active-agent.json (I-03)"

    $passResult = Publish-AirlockActiveAgentCertificate -CertificatePath $certPath -Certificate @{ profileId = "new-profile" } -ContractPassed $true
    Assert-True $passResult.Published "Publish reports published when ContractPassed is true"
    $onDisk2 = Get-Content $certPath -Raw | ConvertFrom-Json
    Assert-True ($onDisk2.profileId -eq "new-profile") "a passed contract atomically replaces the certificate"
} finally {
    Remove-Item -Path $certWorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures agent-state-helpers check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All agent-state-helpers checks passed" -ForegroundColor Green
