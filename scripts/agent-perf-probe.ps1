# agent-perf-probe.ps1 — the vision's "Speed honesty" (docs/10-Product-Vision.md):
# "GPU-fit = interactive; RAM mmap = slow but real; refuse only when even mmap
# won't fit." The SIZED message already estimates throughput ("Expect 1-5
# tok/s") but the number is a hardcoded guess. This probe measures it once per
# session against the live OpenAI-compatible endpoint and reports the real
# figure, so "slow but real" is a measurement, not a slogan.
#
# Deliberately not a gate: a slow measurement warns, it never refuses. The
# vision refuses only when even mmap won't fit - throughput below interactive
# is honest information for the user, not a verdict against the hardware.
function Resolve-AirlockToksPerSec {
    param(
        [Parameter(Mandatory)][int]$CompletionTokens,
        [Parameter(Mandatory)][double]$ElapsedSeconds
    )
    if ($ElapsedSeconds -le 0 -or $CompletionTokens -lt 0) { return $null }
    return [math]::Round($CompletionTokens / $ElapsedSeconds, 1)
}

# One tiny /v1/completions call against a live OpenAI-compatible endpoint.
# Returns @{ ToksPerSec = <double|null>; Reason = <string> }. Never throws -
# a failed probe is "unknown throughput", not a session failure.
function Measure-AirlockEndpointToksPerSec {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model,
        [int]$ProbeTokens = 16,
        [int]$TimeoutSeconds = 120
    )
    $probeUrl = ($BaseUrl.TrimEnd('/')) + '/v1/completions'
    $body = @{
        model       = $Model
        prompt      = 'ping'
        max_tokens  = $ProbeTokens
        temperature = 0
    } | ConvertTo-Json -Compress
    try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = $client.PostAsync($probeUrl, $content).Result
        $sw.Stop()
        $raw = $response.Content.ReadAsStringAsync().Result
        $client.Dispose()
        if (-not $response.IsSuccessStatusCode) {
            return [pscustomobject]@{ ToksPerSec = $null; Reason = "probe HTTP $($response.StatusCode)" }
        }
        $json = $raw | ConvertFrom-Json
        $tokens = 0
        if ($json.usage -and $json.usage.completion_tokens) { $tokens = [int]$json.usage.completion_tokens }
        if ($tokens -le 0) {
            return [pscustomobject]@{ ToksPerSec = $null; Reason = "probe returned no usage.completion_tokens" }
        }
        $tps = Resolve-AirlockToksPerSec -CompletionTokens $tokens -ElapsedSeconds $sw.Elapsed.TotalSeconds
        return [pscustomobject]@{ ToksPerSec = $tps; Reason = "measured ${tokens} tokens in $([math]::Round($sw.Elapsed.TotalSeconds,1))s" }
    } catch {
        return [pscustomobject]@{ ToksPerSec = $null; Reason = "probe failed: $($_.Exception.Message)" }
    }
}

# Pure: classify a measured figure into the vision's own vocabulary.
function Resolve-AirlockThroughputTier {
    param($ToksPerSec)
    if ($null -eq $ToksPerSec) { return 'unknown' }
    if ($ToksPerSec -ge 15) { return 'interactive' }
    if ($ToksPerSec -ge 5) { return 'usable' }
    return 'slow-but-real'
}
