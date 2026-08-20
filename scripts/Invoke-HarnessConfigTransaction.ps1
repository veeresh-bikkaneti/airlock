# Invoke-HarnessConfigTransaction.ps1 — ADR-012 §8.1
# OpenCode (and any harness lacking a per-process endpoint override) needs its
# global config staged for the duration of one session. This is the lock ->
# backup -> stage -> run -> restore -> recover transaction that makes that
# safe: it never overwrites a user's config change made while staged, and it
# never leaves a torn file behind — a hash mismatch on restore preserves a
# recovery record instead of guessing.
#
# Library file — dot-source it (from Start-AgentSession.ps1, ai-doctor, or a
# test) rather than invoking directly. See Test-HarnessConfigTransaction.ps1.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "agent-state-helpers.ps1")

function Backup-AirlockHarnessConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$BackupDir
    )
    if (-not (Test-Path $BackupDir)) { New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null }
    if (-not (Test-Path $ConfigPath)) {
        return [pscustomobject]@{ OriginalAbsent = $true; OriginalHash = $null; BackupPath = $null }
    }
    $hash = (Get-FileHash -Path $ConfigPath -Algorithm SHA256).Hash
    $backupPath = Join-Path $BackupDir "$([System.IO.Path]::GetFileName($ConfigPath)).$([guid]::NewGuid().ToString('N')).bak"
    Copy-Item -Path $ConfigPath -Destination $backupPath
    return [pscustomobject]@{ OriginalAbsent = $false; OriginalHash = $hash; BackupPath = $backupPath }
}

function Set-AirlockStagedHarnessConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Content
    )
    $dir = Split-Path -Parent $ConfigPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $tempPath = Join-Path $dir ".$([System.IO.Path]::GetFileName($ConfigPath)).$([guid]::NewGuid().ToString('N')).tmp"
    Set-Content -Path $tempPath -Value $Content -Encoding utf8NoBOM -NoNewline
    $stagedHash = (Get-FileHash -Path $tempPath -Algorithm SHA256).Hash
    [System.IO.File]::Move($tempPath, $ConfigPath, $true)
    return $stagedHash
}

# Pure: given the current on-disk hash, the hash we staged, and whether the
# original was absent, decide what Restore should do. Never overwrites a
# config a user or another process changed while staged (§8.1 "Restore only
# if the current config hash equals the staged hash. Otherwise stop and
# preserve a recovery record rather than overwrite a user change.").
function Resolve-AirlockConfigRestore {
    param(
        [string]$CurrentHash,
        [Parameter(Mandatory)][string]$StagedHash,
        [Parameter(Mandatory)][bool]$OriginalAbsent
    )
    if ($CurrentHash -ne $StagedHash) {
        return [pscustomobject]@{
            Action = 'PreserveRecoveryRecord'
            Reason = "Current config hash does not match the staged hash - something else changed it since staging. Refusing to overwrite; preserving a recovery record instead."
        }
    }
    if ($OriginalAbsent) {
        return [pscustomobject]@{ Action = 'DeleteConfig'; Reason = "Original was absent before staging and the staged hash still matches - deleting restores absence." }
    }
    return [pscustomobject]@{ Action = 'RestoreBackup'; Reason = "Staged hash matches current config - safe to restore the original from backup." }
}

# Full transaction. -WhatIf performs no filesystem mutation at all (ADR §7.1:
# "-WhatIf ... never starts a process, pulls a model, writes state, invokes a
# harness, or changes a global configuration.").
function Invoke-AirlockHarnessConfigTransaction {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$StagedContent,
        [Parameter(Mandatory)][scriptblock]$Run,
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$TransactionDir,
        [switch]$WhatIf
    )
    if ($WhatIf) {
        return [pscustomobject]@{
            WhatIf = $true
            Plan   = "Would lock $LockPath, back up $ConfigPath to $BackupDir, stage new content, run the harness, then restore or preserve a recovery record."
        }
    }

    if (-not (Test-Path $TransactionDir)) { New-Item -Path $TransactionDir -ItemType Directory -Force | Out-Null }

    $lock = New-AirlockLock -LockPath $LockPath
    $record = [ordered]@{
        sessionId           = $lock.sessionId
        ownerPid            = $lock.ownerPid
        ownerStartTimeTicks = $lock.ownerStartTimeTicks
        configPath        = $ConfigPath
        startedAt         = [DateTime]::UtcNow.ToString('o')
        originalAbsent    = $null
        originalHash      = $null
        backupPath        = $null
        stagedHash        = $null
        processLaunchTime = $null
        restoreResult     = $null
        finishedAt        = $null
    }
    $recordPath = Join-Path $TransactionDir "$($lock.sessionId).json"

    try {
        $backup = Backup-AirlockHarnessConfig -ConfigPath $ConfigPath -BackupDir $BackupDir
        $record.originalAbsent = $backup.OriginalAbsent
        $record.originalHash = $backup.OriginalHash
        $record.backupPath = $backup.BackupPath

        $record.stagedHash = Set-AirlockStagedHarnessConfig -ConfigPath $ConfigPath -Content $StagedContent
        $record.processLaunchTime = [DateTime]::UtcNow.ToString('o')
        Write-AirlockAtomicJson -Path $recordPath -Data $record

        & $Run

        $record.restoreResult = 'RunSucceeded'
    } catch {
        $record.restoreResult = "RunFailed: $($_.Exception.Message)"
        throw
    } finally {
        $currentHash = if (Test-Path $ConfigPath) { (Get-FileHash -Path $ConfigPath -Algorithm SHA256).Hash } else { $null }
        $decision = Resolve-AirlockConfigRestore -CurrentHash $currentHash -StagedHash $record.stagedHash -OriginalAbsent $record.originalAbsent

        switch ($decision.Action) {
            'RestoreBackup' {
                Copy-Item -Path $record.backupPath -Destination $ConfigPath -Force
                $record.restoreResult = "$($record.restoreResult) | Restored: $($decision.Reason)"
            }
            'DeleteConfig' {
                Remove-Item -Path $ConfigPath -Force -ErrorAction SilentlyContinue
                $record.restoreResult = "$($record.restoreResult) | DeletedToRestoreAbsence: $($decision.Reason)"
            }
            'PreserveRecoveryRecord' {
                $record.restoreResult = "$($record.restoreResult) | PRESERVED_FOR_RECOVERY: $($decision.Reason)"
            }
        }
        $record.finishedAt = [DateTime]::UtcNow.ToString('o')
        Write-AirlockAtomicJson -Path $recordPath -Data $record
        Remove-AirlockLock -LockPath $LockPath -SessionId $lock.sessionId
    }

    return [pscustomobject]@{ WhatIf = $false; Record = $record }
}

# ai-opencode-recover / ai-doctor entry point: list transaction records whose
# restore never completed (§8.1 Recover row — "identify orphaned
# transactions and require hash/ownership verification before recovery").
function Get-AirlockOrphanedHarnessTransactions {
    param([Parameter(Mandatory)][string]$TransactionDir)
    if (-not (Test-Path $TransactionDir)) { return @() }
    Get-ChildItem -Path $TransactionDir -Filter '*.json' | ForEach-Object {
        $record = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $isOrphan = ($null -eq $record.restoreResult) -or ($record.restoreResult -match 'PRESERVED_FOR_RECOVERY')
        if ($isOrphan) {
            $ownerProc = Get-Process -Id $record.ownerPid -ErrorAction SilentlyContinue
            $ownerAlive = [bool]($ownerProc -and ($ownerProc.StartTime.ToUniversalTime().Ticks -eq $record.ownerStartTimeTicks))
            [pscustomobject]@{
                RecordPath = $_.FullName
                Record     = $record
                OwnerAlive = $ownerAlive
            }
        }
    }
}
