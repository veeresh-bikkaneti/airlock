#Requires -Version 7.0
<#
.SYNOPSIS
    Validates 3D visualizer scenes against the published schema and the renderer's real
    requirements. Exit 0 = every scene will render; exit 1 = at least one will not.

.DESCRIPTION
    The point of this script (ADR-010): scene authoring is a bounded, checkable task, so an
    agent writing a scene has a loop it can close without ever seeing pixels. Structural rules
    the renderer depends on — every edge names a real node, every flow hop has a matching edge,
    every narrated flow has exactly one step per hop — are enforced here rather than discovered
    as a blank screen.

.PARAMETER Path
    A specific scene file. Omit to validate every scene listed in scenes/manifest.json.

.EXAMPLE
    .\scripts\Test-Scene.ps1
    .\scripts\Test-Scene.ps1 -Path tools/3d-system-visualizer/scenes/airlock-first-run.json
#>
[CmdletBinding()]
param([string]$Path)

$ErrorActionPreference = 'Stop'
$sceneDir = Join-Path $PSScriptRoot '..' 'tools' '3d-system-visualizer' 'scenes'
$sceneDir = (Resolve-Path $sceneDir).Path

$validTypes  = @('service', 'datastore', 'infra', 'external', 'user')
$validStatus = @('healthy', 'degraded', 'down')
$validModes  = @('auto', 'guided')

function Test-OneScene {
    param([string]$File)

    $name = Split-Path $File -Leaf
    $errors = @()
    $warnings = @()

    try {
        $scene = Get-Content $File -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ Name = $name; Errors = @("not valid JSON: $($_.Exception.Message)"); Warnings = @() }
    }

    if (-not $scene.nodes) { $errors += "no 'nodes' array" }
    if (-not $scene.edges) { $errors += "no 'edges' array" }
    if ($errors) { return [pscustomobject]@{ Name = $name; Errors = $errors; Warnings = @() } }

    # --- nodes ---
    $ids = @{}
    $positions = @{}
    foreach ($n in $scene.nodes) {
        if (-not $n.id)    { $errors += "a node has no 'id'"; continue }
        if (-not $n.label) { $errors += "node '$($n.id)' has no 'label'" }
        if ($n.id -cnotmatch '^[a-z0-9_]+$') { $errors += "node id '$($n.id)' must be lowercase letters, digits, underscores" }
        if ($ids.ContainsKey($n.id)) { $errors += "duplicate node id '$($n.id)'" }
        $ids[$n.id] = $true

        if (-not $n.pos -or $n.pos.Count -ne 3) {
            $errors += "node '$($n.id)' needs a 'pos' of exactly 3 numbers"
        } else {
            $key = ($n.pos -join ',')
            if ($positions.ContainsKey($key)) { $errors += "node '$($n.id)' sits exactly on top of '$($positions[$key])' at [$key]" }
            $positions[$key] = $n.id
        }

        if ($n.label -and $n.label.Length -gt 28) { $warnings += "node '$($n.id)' label is $($n.label.Length) chars — long labels overflow the box face" }
        if ($n.type   -and $n.type   -notin $validTypes)  { $errors += "node '$($n.id)' has type '$($n.type)' (allowed: $($validTypes -join ', '))" }
        if ($n.status -and $n.status -notin $validStatus) { $errors += "node '$($n.id)' has status '$($n.status)' (allowed: $($validStatus -join ', '))" }
    }

    if ($scene.nodes.Count -gt 20) { $warnings += "$($scene.nodes.Count) nodes — above ~20 the graph stops being readable; consider splitting the scene" }

    # --- edges ---
    $edgeSet = @{}
    foreach ($e in $scene.edges) {
        if (-not $e.from -or -not $e.to) { $errors += "an edge is missing 'from' or 'to'"; continue }
        if (-not $ids.ContainsKey($e.from)) { $errors += "edge '$($e.from)' -> '$($e.to)': no node with id '$($e.from)'" }
        if (-not $ids.ContainsKey($e.to))   { $errors += "edge '$($e.from)' -> '$($e.to)': no node with id '$($e.to)'" }
        if ($e.from -eq $e.to)              { $errors += "edge '$($e.from)' -> itself is not renderable" }
        $edgeSet["$($e.from)->$($e.to)"] = $true
        if ($null -ne $e.latencyMs -and $e.latencyMs -lt 0) { $errors += "edge '$($e.from)' -> '$($e.to)' has negative latencyMs" }
    }

    # --- flows ---
    foreach ($f in $scene.flows) {
        if (-not $f.name) { $errors += "a flow has no 'name'" }
        $label = if ($f.name) { $f.name } else { '(unnamed)' }

        if (-not $f.path -or $f.path.Count -lt 2) {
            $errors += "flow '$label' needs a 'path' of at least 2 node ids"
            continue
        }

        foreach ($id in $f.path) {
            if (-not $ids.ContainsKey($id)) { $errors += "flow '$label' walks through '$id', which is not a node in this scene" }
        }

        for ($i = 0; $i -lt $f.path.Count - 1; $i++) {
            $hop = "$($f.path[$i])->$($f.path[$i + 1])"
            if (-not $edgeSet.ContainsKey($hop)) { $errors += "flow '$label' hop $($i + 1) ($hop) has no matching edge — the animation would jump through empty space" }
        }

        if ($f.mode -and $f.mode -notin $validModes) { $errors += "flow '$label' has mode '$($f.mode)' (allowed: $($validModes -join ', '))" }

        if ($f.steps) {
            $expected = $f.path.Count - 1
            if ($f.steps.Count -ne $expected) {
                $errors += "flow '$label' has $($f.steps.Count) steps but $expected hops — narration must have exactly one entry per hop"
            }
            $idx = 0
            foreach ($s in $f.steps) {
                $idx++
                if (-not $s.caption) { $errors += "flow '$label' step $idx has no 'caption'" }
                elseif ($s.caption.Length -gt 90) { $warnings += "flow '$label' step $idx caption is $($s.caption.Length) chars — keep captions to one readable line" }
            }
            if ($f.mode -ne 'guided') { $warnings += "flow '$label' has narration but mode is '$(if ($f.mode) { $f.mode } else { 'auto' })' — captions are only shown in 'guided' mode" }
        }
    }

    return [pscustomobject]@{ Name = $name; Errors = $errors; Warnings = $warnings }
}

# --- collect scenes ---
$files = @()
if ($Path) {
    $files = @((Resolve-Path $Path).Path)
} else {
    $manifestPath = Join-Path $sceneDir 'manifest.json'
    if (-not (Test-Path $manifestPath)) { Write-Host "No manifest.json at $manifestPath" -ForegroundColor Red; exit 1 }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    foreach ($entry in $manifest) {
        $f = Join-Path $sceneDir $entry.file
        if (Test-Path $f) {
            $files += $f
        } else {
            # A live scene is generated on demand and gitignored, so a missing one in CI is
            # expected rather than a failure. A missing committed scene is a real problem.
            Write-Host "SKIP  $($entry.file) — listed in manifest but not present (generated scene?)" -ForegroundColor DarkGray
        }
    }
}

Write-Host "Scene validation" -ForegroundColor Cyan
Write-Host "================" -ForegroundColor DarkCyan

$failed = 0
foreach ($f in $files) {
    $r = Test-OneScene -File $f
    if ($r.Errors.Count -eq 0) {
        Write-Host "  PASS  $($r.Name)" -ForegroundColor Green
    } else {
        $failed++
        Write-Host "  FAIL  $($r.Name)" -ForegroundColor Red
        foreach ($e in $r.Errors) { Write-Host "          $e" -ForegroundColor Red }
    }
    foreach ($w in $r.Warnings) { Write-Host "          warn: $w" -ForegroundColor Yellow }
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "  $failed scene(s) would not render correctly." -ForegroundColor Red
    exit 1
}
Write-Host "  All $($files.Count) scene(s) valid." -ForegroundColor Green
exit 0
