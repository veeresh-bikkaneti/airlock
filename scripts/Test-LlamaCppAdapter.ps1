# Self-check for runtime-adapters/llamacpp.ps1 (ADR-012 Phase D, §6/§6.2).
# Covers the pure decision logic and port/base-URL helpers only -
# Start-LlamaCppRuntime/Get-LlamaCppInspection/Stop-LlamaCppIfOwned require a
# real llama-server binary and GPU (§10.2 live acceptance suite; this
# environment has neither). Resolve-LlamaCppTemplateVerification is the one
# thing this phase can fully prove without hardware: the ADR's explicit
# "never silently proceed on an unrecognized or absent template" failure
# mode. The runtime-agnostic acquisition-gate/StopIfOwned checks already
# live in Test-AdapterContractHelpers.ps1 and are reused here, not retested.
# Run: pwsh -File scripts/Test-LlamaCppAdapter.ps1
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "runtime-adapters" "llamacpp.ps1")

$failures = 0
function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if ($Condition) { Write-Host "PASS: $Message" -ForegroundColor Green }
    else { Write-Host "FAIL: $Message" -ForegroundColor Red; $script:failures++ }
}

Write-Host "Testing runtime-adapters/llamacpp.ps1..." -ForegroundColor Cyan

# --- Resolve-LlamaCppTemplateVerification: the critical fail-closed decision ---

$r1 = Resolve-LlamaCppTemplateVerification -PropsReachable $false
Assert-True ($r1.Verdict -eq 'template_unverified') "/props unreachable -> template_unverified"

$r2 = Resolve-LlamaCppTemplateVerification -PropsReachable $true -TemplateText ''
Assert-True ($r2.Verdict -eq 'template_unverified') "/props reachable but no chat_template -> template_unverified"

$r3 = Resolve-LlamaCppTemplateVerification -PropsReachable $true -TemplateText '   '
Assert-True ($r3.Verdict -eq 'template_unverified') "/props reachable but whitespace-only chat_template -> template_unverified"

$r4 = Resolve-LlamaCppTemplateVerification -PropsReachable $true -TemplateText '{% for message in messages %}{{ message.role }}: {{ message.content }}{% endfor %}'
Assert-True ($r4.Verdict -eq 'template_unverified') "chat_template present but no recognized tool-call marker -> template_unverified, not assumed capable"

$r5 = Resolve-LlamaCppTemplateVerification -PropsReachable $true -TemplateText 'system prompt includes <tool_call>{"name": ..., "arguments": ...}</tool_call> markup'
Assert-True ($r5.Verdict -eq 'Pass') "chat_template with <tool_call> marker -> Pass"

$r6 = Resolve-LlamaCppTemplateVerification -PropsReachable $true -TemplateText 'emits [TOOL_CALLS] [{"name": "fn", "arguments": {}}]'
Assert-True ($r6.Verdict -eq 'Pass') "chat_template with Mistral-style [TOOL_CALLS] marker -> Pass"

$r7 = Resolve-LlamaCppTemplateVerification -PropsReachable $true -TemplateText 'declares <tools>[...]</tools> in the system block'
Assert-True ($r7.Verdict -eq 'Pass') "chat_template with <tools> system-block marker -> Pass"

$r8 = Resolve-LlamaCppTemplateVerification -PropsReachable $true -TemplateText 'uses TOOL_CALL casing variants'
Assert-True ($r8.Verdict -eq 'Pass') "marker matching is case-insensitive"

# Never a silent proceed on default/unspecified params (only PropsReachable given, no template info at all).
$r9 = Resolve-LlamaCppTemplateVerification -PropsReachable $true
Assert-True ($r9.Verdict -eq 'template_unverified') "reachable /props with no template info supplied at all -> template_unverified by default, never Pass"

# --- Resolve-LlamaCppEndpointMode: single openai-direct candidate for every harness (§3, §6.2) ---

foreach ($h in @('opencode', 'pi-worker', 'aider', 'openclaw')) {
    $mode = Resolve-LlamaCppEndpointMode -Harness $h
    Assert-True (($mode.TransportCandidates -join ',') -eq 'openai-direct') "$h gets exactly one transport candidate: openai-direct (no native/proxy split for llama.cpp)"
}

# --- Get-AirlockFreeLoopbackPort: returns a usable loopback port ---

$port1 = Get-AirlockFreeLoopbackPort
Assert-True ($port1 -gt 0 -and $port1 -le 65535) "Get-AirlockFreeLoopbackPort returns a port in the valid range"
$port2 = Get-AirlockFreeLoopbackPort
Assert-True ($port2 -gt 0 -and $port2 -le 65535) "Get-AirlockFreeLoopbackPort returns a usable port on a second call too (listener released after first)"

# --- Get-AirlockLlamaCppBaseUrl: snapshot-file convention, no fixed default (unlike Ollama) ---

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-llamacpp-adapter-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    $stateDir = Join-Path $workDir "state"
    New-Item -Path $stateDir -ItemType Directory -Force | Out-Null

    $noSnapshot = Get-AirlockLlamaCppBaseUrl -PlatformDir $workDir
    Assert-True ($null -eq $noSnapshot) "with no llamacpp-instance.json, base URL is null - llama.cpp has no fixed default port to fall back to"

    Set-Content -Path (Join-Path $stateDir "llamacpp-instance.json") -Value '{"port":38123}' -Encoding utf8NoBOM
    $withSnapshot = Get-AirlockLlamaCppBaseUrl -PlatformDir $workDir
    Assert-True ($withSnapshot -eq "http://127.0.0.1:38123") "with a llamacpp-instance.json snapshot present, the recorded Airlock-selected port is used"
} finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Stop-LlamaCppIfOwned: no recorded instance -> refused, nothing to stop ---

$stopWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "airlock-llamacpp-stop-test-$([guid]::NewGuid().ToString('N'))"
New-Item -Path $stopWorkDir -ItemType Directory -Force | Out-Null
try {
    $stopResult = Stop-LlamaCppIfOwned -PlatformDir $stopWorkDir
    Assert-True (-not $stopResult.Stopped) "Stop-LlamaCppIfOwned with no recorded instance file refuses to stop anything"
} finally {
    Remove-Item -Path $stopWorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "$failures llama.cpp adapter check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All llama.cpp adapter checks passed" -ForegroundColor Green
exit 0
