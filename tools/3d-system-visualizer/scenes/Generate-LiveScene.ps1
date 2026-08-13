# Generate-LiveScene.ps1 — turns this platform's own real audit log into a
# scene for the 3D visualizer, instead of the fictional e-commerce demo.
#
# Usage: .\Generate-LiveScene.ps1 [-LogDate yyyy-MM-dd]
#   Defaults to today's log, falling back to the most recent log file if
#   today has none yet (e.g. platform hasn't been started today).
#
# ponytail: static snapshot generated on demand, not a live-streaming
# server. Re-run this after using the platform to refresh the scene with
# whatever happened since. A real-time feed would need a small local HTTP
# server tailing the log — add one if on-demand regeneration stops being
# enough, not before.

param([string]$LogDate)

$ErrorActionPreference = "Stop"
$LogDir = "$env:USERPROFILE\.ai-platform\logs"
$OutFile = Join-Path $PSScriptRoot "local-ai-platform-live.json"

if ($LogDate) {
    $LogFile = Join-Path $LogDir "$LogDate.jsonl"
    if (-not (Test-Path $LogFile)) { throw "No log for $LogDate at $LogFile" }
} else {
    $today = Join-Path $LogDir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
    if (Test-Path $today) {
        $LogFile = $today
    } else {
        $LogFile = Get-ChildItem "$LogDir\*.jsonl" -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
}

Write-Host "Reading $LogFile" -ForegroundColor Cyan

# Fixed architecture — this platform's real components, not per-run data.
# pos values are hand-placed for a readable layout, same convention as the
# e-commerce demo scene.
$nodes = @(
    @{ id = "cli";       label = "ai-start / VS Code";  pos = @(-8, 2, 0);  type = "external" }
    @{ id = "start";     label = "Start-AI.ps1";        pos = @(-4, 2, 0);  type = "service" }
    @{ id = "backend";   label = "Backend Selection";   pos = @(0, 2, 0);   type = "service" }
    @{ id = "ollama";    label = "Ollama Engine";       pos = @(4, 3, -2);  type = "service" }
    @{ id = "vllm";      label = "vLLM Container";      pos = @(4, 1, 2);   type = "service" }
    @{ id = "models";    label = "Model Store";         pos = @(8, 3, -2);  type = "datastore" }
    @{ id = "firewall";  label = "Firewall Guard";      pos = @(4, -1, 0);  type = "infra" }
    @{ id = "stop";      label = "Stop-AI.ps1";         pos = @(0, -2, 0);  type = "service" }
    @{ id = "audit";     label = "Audit Log";           pos = @(-4, -2, 0); type = "datastore" }
)

# Real observed action -> node-pair mapping. Only actions with clear
# before/after semantics get an edge; pure internal checks (ResourceCheck,
# PowerShellCheck) are skipped rather than forced into a fake self-loop.
function Resolve-EdgeForAction($action, $provider, $result) {
    switch ($action) {
        "PlatformStart"    { if ($result -eq "STARTED") { return @("cli", "start") } else { return @("start", "audit") } }
        "BackendSelected"  { return @("start", "backend") }
        "BackendFallback"  { return @("backend", "ollama") }
        "OllamaStart"      { return @("backend", "ollama") }
        "VLLMStart"        { return @("backend", "vllm") }
        "ModelPull"        { return @("ollama", "models") }
        "ModelSwitch"      { return @("ollama", "models") }
        "FirewallGuard"    { if ($provider -eq "vllm") { return @("vllm", "firewall") } else { return @("ollama", "firewall") } }
        "OllamaStop"       { return @("ollama", "stop") }
        "VLLMStop"         { return @("vllm", "stop") }
        "PlatformShutdown" { if ($result -eq "STARTED") { return @("start", "stop") } else { return @("stop", "audit") } }
        default            { return $null }
    }
}

$entries = Get-Content $LogFile | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch { $null }
} | Where-Object { $_ -and $_.timestampUtc -and $_.action }

if (-not $entries -or $entries.Count -eq 0) {
    throw "No parseable audit-log entries in $LogFile"
}

# Union of every edge actually observed at least once — real transitions
# only, nothing speculative.
$edgeSet = [ordered]@{}
foreach ($e in $entries) {
    $pair = Resolve-EdgeForAction $e.action $e.provider $e.result
    if ($pair) {
        $key = "$($pair[0])->$($pair[1])"
        if (-not $edgeSet.Contains($key)) {
            $edgeSet[$key] = @{ from = $pair[0]; to = $pair[1]; label = $e.action }
        }
    }
}
$edges = @($edgeSet.Values)

# One flow per session (a run gap of >5 min starts a new session), replaying
# the real sequence of node-pairs visited, at a speed derived from real
# elapsed time between consecutive log lines so faster real transitions
# animate faster.
$sessions = @()
$current = @()
$prevTime = $null
foreach ($e in $entries) {
    $t = [DateTime]::Parse($e.timestampUtc).ToUniversalTime()
    if ($prevTime -and ($t - $prevTime).TotalMinutes -gt 5 -and $current.Count -gt 0) {
        $sessions += , $current
        $current = @()
    }
    $current += , @{ entry = $e; time = $t }
    $prevTime = $t
}
if ($current.Count -gt 0) { $sessions += , $current }

$flows = @()
$flowIndex = 0
foreach ($session in $sessions) {
    # FlowAnimator requires every consecutive pair in a flow's path to be a
    # real edge - "vllm->vllm" or any other discontinuous hop throws at
    # runtime. Only extend the current path when this action's "from"
    # actually matches where the path currently stands; otherwise close off
    # what's built so far (if long enough to show) and start a new one.
    # Immediate exact repeats (the same edge firing twice in a row, e.g. two
    # near-identical audit lines for one real event) are collapsed too.
    $path = @()
    $pathStart = $null
    $segEntries = @()

    # A flow's card in the UI needs to say what actually happened, not just when -
    # "provider" (which backend) and "outcome" (worst result seen) are derived from
    # the same log entries that built the path, not guessed separately.
    function Emit-PathAsFlow($p, $startTime, $endTime, $entries) {
        if ($p.Count -lt 2) { return }
        $span = ($endTime - $startTime).TotalSeconds
        $speed = if ($span -gt 0) { [Math]::Max(0.5, [Math]::Min(6, ($p.Count - 1) * 3 / $span)) } else { 2 }

        $provider = ($entries | Where-Object { $_.provider } | Select-Object -Last 1 -ExpandProperty provider)
        if (-not $provider) { $provider = "ollama" }
        $outcome = if ($entries | Where-Object { $_.result -eq "FAILED" }) { "failed" }
                   elseif ($entries | Where-Object { $_.result -eq "WARNING" }) { "warning" }
                   else { "ok" }

        $script:flowIndex++
        $script:flows += @{
            name     = "Run $($script:flowIndex): $($startTime.ToString('HH:mm:ss')) UTC"
            path     = $p
            loop     = $true
            speed    = [Math]::Round($speed, 2)
            provider = $provider
            outcome  = $outcome
        }
    }

    for ($i = 0; $i -lt $session.Count; $i++) {
        $e = $session[$i].entry
        $pair = Resolve-EdgeForAction $e.action $e.provider $e.result
        if (-not $pair) { continue }

        if ($path.Count -eq 0) {
            $path = @($pair[0], $pair[1])
            $pathStart = $session[$i].time
            $segEntries = @($e)
        } elseif ($path[-1] -eq $pair[0] -and $path[-1] -ne $pair[1]) {
            $path += $pair[1]
            $segEntries += $e
        } elseif ($path[-1] -eq $pair[0] -and $path[-1] -eq $pair[1]) {
            continue # exact immediate repeat, nothing new to show
        } else {
            Emit-PathAsFlow $path $pathStart $session[$i].time $segEntries
            $path = @($pair[0], $pair[1])
            $pathStart = $session[$i].time
            $segEntries = @($e)
        }
    }
    Emit-PathAsFlow $path $pathStart $session[-1].time $segEntries
}

if ($flows.Count -eq 0) {
    Write-Host "No node-mappable actions found - writing architecture with no flows." -ForegroundColor Yellow
}

$scene = @{ nodes = $nodes; edges = $edges; flows = $flows }
$scene | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding utf8NoBOM

Write-Host "Wrote $OutFile - $($nodes.Count) nodes, $($edges.Count) edges, $($flows.Count) flow(s) from $($entries.Count) log lines" -ForegroundColor Green

# Register in the manifest if not already present.
$ManifestFile = Join-Path $PSScriptRoot "manifest.json"
# @() forces array context - ConvertFrom-Json unwraps a single-element JSON
# array to a bare object, which then breaks += (PSObject has no op_Addition).
$manifest = @(Get-Content $ManifestFile -Raw | ConvertFrom-Json)
if (-not ($manifest | Where-Object { $_.file -eq "local-ai-platform-live.json" })) {
    $manifest += [PSCustomObject]@{ name = "local-ai-platform (live)"; file = "local-ai-platform-live.json" }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $ManifestFile -Encoding utf8NoBOM
    Write-Host "Registered in manifest.json" -ForegroundColor Green
}
