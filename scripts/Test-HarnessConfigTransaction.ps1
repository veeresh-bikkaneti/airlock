# Self-check for Invoke-HarnessConfigTransaction.ps1 (ADR-012 Phase A, §8.1).
# Run: pwsh -File scripts/Test-HarnessConfigTransaction.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "Invoke-HarnessConfigTransaction.ps1")

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

Write-Host "Testing Invoke-HarnessConfigTransaction.ps1..." -ForegroundColor Cyan

# --- Resolve-AirlockConfigRestore (pure decision logic) ---

$r1 = Resolve-AirlockConfigRestore -CurrentHash "abc" -StagedHash "abc" -OriginalAbsent $false
Assert-True ($r1.Action -eq 'RestoreBackup') "hash matches, original existed -> RestoreBackup"

$r2 = Resolve-AirlockConfigRestore -CurrentHash "abc" -StagedHash "abc" -OriginalAbsent $true
Assert-True ($r2.Action -eq 'DeleteConfig') "hash matches, original was absent -> DeleteConfig"

$r3 = Resolve-AirlockConfigRestore -CurrentHash "abc" -StagedHash "xyz" -OriginalAbsent $false
Assert-True ($r3.Action -eq 'PreserveRecoveryRecord') "hash mismatch (torn/changed state) -> PreserveRecoveryRecord, never guess"

$r4 = Resolve-AirlockConfigRestore -CurrentHash $null -StagedHash "xyz" -OriginalAbsent $false
Assert-True ($r4.Action -eq 'PreserveRecoveryRecord') "config deleted out from under us mid-session -> PreserveRecoveryRecord, not silently accepted"

# --- Full transaction round trip (real I/O, isolated temp dir) ---

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-config-txn-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $configPath = Join-Path $workDir "config" "opencode.json"
    $lockPath = Join-Path $workDir "lock" "opencode.lock"
    $backupDir = Join-Path $workDir "backups"
    $txnDir = Join-Path $workDir "transactions"

    New-Item -Path (Split-Path -Parent $configPath) -ItemType Directory -Force | Out-Null
    Set-Content -Path $configPath -Value '{"original":true}' -Encoding utf8NoBOM -NoNewline
    $originalHash = (Get-FileHash $configPath -Algorithm SHA256).Hash

    $ranInsideTransaction = $false
    $stagedContentSeenByRun = $null
    $result = Invoke-AirlockHarnessConfigTransaction -ConfigPath $configPath -StagedContent '{"staged":true}' `
        -LockPath $lockPath -BackupDir $backupDir -TransactionDir $txnDir `
        -Run {
            $script:ranInsideTransaction = $true
            $script:stagedContentSeenByRun = Get-Content $configPath -Raw
        }

    Assert-True $ranInsideTransaction "the Run scriptblock executes inside the transaction"
    Assert-True ($stagedContentSeenByRun -eq '{"staged":true}') "the harness sees the staged config while Run executes"
    Assert-True ((Get-Content $configPath -Raw) -eq '{"original":true}') "config is restored to its original content after a successful run"
    Assert-True ((Get-FileHash $configPath -Algorithm SHA256).Hash -eq $originalHash) "restored config hash matches the pre-transaction original"
    Assert-True (-not (Test-Path $lockPath)) "lock is released after the transaction completes"
    Assert-True ($result.Record.restoreResult -match 'RunSucceeded') "transaction record notes the run succeeded"
    Assert-True ($result.Record.restoreResult -match 'Restored:') "transaction record notes the restore action taken"

    # --- Failure path: Run throws, config must still be restored, error still propagates ---
    $threw = $false
    try {
        Invoke-AirlockHarnessConfigTransaction -ConfigPath $configPath -StagedContent '{"staged":true}' `
            -LockPath $lockPath -BackupDir $backupDir -TransactionDir $txnDir `
            -Run { throw "simulated harness failure" }
    } catch {
        $threw = $true
    }
    Assert-True $threw "a failing Run scriptblock's error still propagates to the caller"
    Assert-True ((Get-Content $configPath -Raw) -eq '{"original":true}') "config is restored even when Run throws"
    Assert-True (-not (Test-Path $lockPath)) "lock is released even when Run throws"

    # --- Original-absent path: config didn't exist before staging ---
    $absentConfigPath = Join-Path $workDir "config" "new-harness.json"
    Invoke-AirlockHarnessConfigTransaction -ConfigPath $absentConfigPath -StagedContent '{"staged":true}' `
        -LockPath $lockPath -BackupDir $backupDir -TransactionDir $txnDir `
        -Run { } | Out-Null
    Assert-True (-not (Test-Path $absentConfigPath)) "config that didn't exist before staging is removed (restores absence), not left behind"

    # --- Tampered-during-run path: something else changes the config mid-run -> preserved, not overwritten ---
    Set-Content -Path $configPath -Value '{"original":true}' -Encoding utf8NoBOM -NoNewline
    $tamperResult = Invoke-AirlockHarnessConfigTransaction -ConfigPath $configPath -StagedContent '{"staged":true}' `
        -LockPath $lockPath -BackupDir $backupDir -TransactionDir $txnDir `
        -Run { Set-Content -Path $configPath -Value '{"tampered":true}' -Encoding utf8NoBOM -NoNewline }
    Assert-True ((Get-Content $configPath -Raw) -eq '{"tampered":true}') "config changed by something else during Run is never silently overwritten on restore"
    Assert-True ($tamperResult.Record.restoreResult -match 'PRESERVED_FOR_RECOVERY') "a hash mismatch on restore is recorded as a recovery case, not silently dropped"

    $orphans = Get-AirlockOrphanedHarnessTransactions -TransactionDir $txnDir
    Assert-True (($orphans | Where-Object { $_.Record.restoreResult -match 'PRESERVED_FOR_RECOVERY' }).Count -ge 1) "Get-AirlockOrphanedHarnessTransactions surfaces the preserved-for-recovery transaction"

    # --- Invoke-AirlockOrphanedHarnessTransactionRecovery: the abandoned-mid-flight case (BUG FOUND BY A LIVE RUN) ---
    # Simulates exactly what a killed pwsh process leaves behind: staged
    # content already on disk, a backup of the original, and a transaction
    # record whose restoreResult never got set because nothing ever reached
    # the finally block.
    $abandonedConfigPath = Join-Path $workDir "config" "abandoned-harness.json"
    Set-Content -Path $abandonedConfigPath -Value '{"staged":true}' -Encoding utf8NoBOM -NoNewline
    $abandonedStagedHash = (Get-FileHash $abandonedConfigPath -Algorithm SHA256).Hash
    $abandonedBackupPath = Join-Path $backupDir "abandoned-harness.json.$([guid]::NewGuid().ToString('N')).bak"
    Set-Content -Path $abandonedBackupPath -Value '{"original":true}' -Encoding utf8NoBOM -NoNewline
    $abandonedRecord = [ordered]@{
        sessionId           = [guid]::NewGuid().ToString()
        ownerPid            = 999999  # not a real, live process
        ownerStartTimeTicks = 1
        configPath          = $abandonedConfigPath
        startedAt           = [DateTime]::UtcNow.ToString('o')
        originalAbsent      = $false
        originalHash        = "irrelevant-for-this-test"
        backupPath          = $abandonedBackupPath
        stagedHash          = $abandonedStagedHash
        processLaunchTime   = [DateTime]::UtcNow.ToString('o')
        restoreResult       = $null
        finishedAt          = $null
    }
    Write-AirlockAtomicJson -Path (Join-Path $txnDir "$($abandonedRecord.sessionId).json") -Data $abandonedRecord

    $recovered = Invoke-AirlockOrphanedHarnessTransactionRecovery -TransactionDir $txnDir
    Assert-True (($recovered | Where-Object { $_.SessionId -eq $abandonedRecord.sessionId }).Count -eq 1) "the abandoned (restoreResult=null, dead owner) transaction is recovered"
    Assert-True ((Get-Content $abandonedConfigPath -Raw) -eq '{"original":true}') "recovery restores the original content from backup"
    $recoveredRecord = Get-Content (Join-Path $txnDir "$($abandonedRecord.sessionId).json") -Raw | ConvertFrom-Json
    Assert-True ($recoveredRecord.restoreResult -match 'OrphanRecovery') "the transaction record is updated so it is never re-swept as an orphan again"
    Assert-True ((Invoke-AirlockOrphanedHarnessTransactionRecovery -TransactionDir $txnDir | Where-Object { $_.SessionId -eq $abandonedRecord.sessionId }).Count -eq 0) "re-running recovery is a no-op for an already-recovered transaction"
    Assert-True ((Invoke-AirlockOrphanedHarnessTransactionRecovery -TransactionDir $txnDir | Where-Object { $_.SessionId -eq $tamperResult.Record.sessionId }).Count -eq 0) "a transaction already correctly PRESERVED_FOR_RECOVERY is left alone, never auto-overwritten"

    # --- -WhatIf: no mutation at all ---
    Set-Content -Path $configPath -Value '{"original":true}' -Encoding utf8NoBOM -NoNewline
    $beforeHash = (Get-FileHash $configPath -Algorithm SHA256).Hash
    $whatIfRan = $false
    $whatIfResult = Invoke-AirlockHarnessConfigTransaction -ConfigPath $configPath -StagedContent '{"staged":true}' `
        -LockPath $lockPath -BackupDir $backupDir -TransactionDir $txnDir `
        -Run { $script:whatIfRan = $true } -WhatIf
    Assert-True $whatIfResult.WhatIf "-WhatIf result is flagged as such"
    Assert-True (-not $whatIfRan) "-WhatIf never executes the Run scriptblock"
    Assert-True ((Get-FileHash $configPath -Algorithm SHA256).Hash -eq $beforeHash) "-WhatIf leaves the config file completely untouched"
    Assert-True (-not (Test-Path $lockPath)) "-WhatIf never creates a lock file"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures Invoke-HarnessConfigTransaction check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All Invoke-HarnessConfigTransaction checks passed" -ForegroundColor Green
exit 0
