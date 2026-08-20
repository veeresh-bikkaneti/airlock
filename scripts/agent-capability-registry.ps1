# agent-capability-registry.ps1 — ADR-012 §5.2
# state/capability-registry.json accessor. Pass and failure entries carry
# distinct short TTLs; -ForceVerify bypasses both (always re-run the
# contract); -NoCache bypasses both read AND write (never touches the file).
# $PSScriptRoot (not a hand-assigned $ScriptDir) - immune to being clobbered
# by a dot-sourced file elsewhere in the chain reassigning the same name.
. (Join-Path $PSScriptRoot "agent-state-helpers.ps1")

# Pure: given what's on disk (if anything) and the flags, decide whether a
# cached entry should be used. Kept separate from the file read so the four
# §5.2 behaviors (fresh pass, fresh fail, expired, force/no-cache) are each
# one direct assertion in Test-AgentCapabilityRegistry.ps1.
function Resolve-AirlockCapabilityCacheRead {
    param(
        [bool]$EntryExists = $false,
        [Nullable[DateTime]]$ExpiresAtUtc = $null,
        [Parameter(Mandatory)][DateTime]$NowUtc,
        [switch]$ForceVerify,
        [switch]$NoCache
    )
    if ($NoCache) {
        return [pscustomobject]@{ UseCache = $false; Reason = "-NoCache: never reads (or writes) the registry." }
    }
    if ($ForceVerify) {
        return [pscustomobject]@{ UseCache = $false; Reason = "-ForceVerify: always re-runs the contract regardless of any cached entry." }
    }
    if (-not $EntryExists) {
        return [pscustomobject]@{ UseCache = $false; Reason = "No cached entry for this evidence key." }
    }
    if ($NowUtc -ge $ExpiresAtUtc) {
        return [pscustomobject]@{ UseCache = $false; Reason = "Cached entry expired at $($ExpiresAtUtc.ToString('o'))." }
    }
    return [pscustomobject]@{ UseCache = $true; Reason = "Fresh cached entry, reused without re-running the contract." }
}

function Get-AirlockCapabilityEntry {
    param(
        [Parameter(Mandatory)][string]$EvidenceKey,
        [Parameter(Mandatory)][string]$RegistryPath,
        [switch]$ForceVerify,
        [switch]$NoCache
    )
    $exists = $false
    $entry = $null
    $expiresAtUtc = $null
    if ((-not $NoCache) -and (Test-Path $RegistryPath)) {
        $registry = Get-Content $RegistryPath -Raw | ConvertFrom-Json
        $entry = $registry.entries.$EvidenceKey
        if ($entry) {
            $exists = $true
            $expiresAtUtc = [DateTime]::Parse($entry.expiresAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
    }
    $decision = Resolve-AirlockCapabilityCacheRead -EntryExists $exists -ExpiresAtUtc $expiresAtUtc -NowUtc ([DateTime]::UtcNow) -ForceVerify:$ForceVerify -NoCache:$NoCache
    if ($decision.UseCache) {
        return [pscustomobject]@{ Entry = $entry; FromCache = $true; Reason = $decision.Reason }
    }
    return [pscustomobject]@{ Entry = $null; FromCache = $false; Reason = $decision.Reason }
}

# §5.2: pass and failure entries have distinct short TTLs. -NoCache never
# writes either.
function Set-AirlockCapabilityEntry {
    param(
        [Parameter(Mandatory)][string]$EvidenceKey,
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail')][string]$Verdict,
        [Parameter(Mandatory)]$EntryData,
        [Parameter(Mandatory)][int]$PassTtlMinutes,
        [Parameter(Mandatory)][int]$FailTtlMinutes,
        [switch]$NoCache
    )
    if ($NoCache) {
        return [pscustomobject]@{ Written = $false; Reason = "-NoCache: never writes the registry." }
    }
    $ttlMinutes = if ($Verdict -eq 'pass') { $PassTtlMinutes } else { $FailTtlMinutes }
    $now = [DateTime]::UtcNow
    $entry = $EntryData | Select-Object *
    $entry | Add-Member -NotePropertyName 'verdict' -NotePropertyValue $Verdict -Force
    $entry | Add-Member -NotePropertyName 'provenAt' -NotePropertyValue $now.ToString('o') -Force
    $entry | Add-Member -NotePropertyName 'expiresAt' -NotePropertyValue $now.AddMinutes($ttlMinutes).ToString('o') -Force

    $registry = if (Test-Path $RegistryPath) { Get-Content $RegistryPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{ schemaVersion = 1; entries = [pscustomobject]@{} } }
    $registry.entries | Add-Member -NotePropertyName $EvidenceKey -NotePropertyValue $entry -Force
    Write-AirlockAtomicJson -Path $RegistryPath -Data $registry -Depth 10
    return [pscustomobject]@{ Written = $true; Reason = "Wrote a $Verdict entry with a $ttlMinutes-minute TTL." }
}
