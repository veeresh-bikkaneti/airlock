# PowerShell Module Spec

## Goal
Define a small PowerShell command surface that is secure, observable, and easy to maintain.

## Recommended Commands
- `ai-start` — start local services, load policy, select provider, initialize session state.
- `ai-stop` — stop local services, clear session variables, write shutdown logs.
- `ai-port` — display current local endpoint and health.
- `ai-provider` — show active provider, model, endpoint, and fallback reason if applicable.
- `ai-code` — launch aider with the active provider configuration.
- `ai-audit-last` — show the most recent structured log entries.
- `ai-policy` — display current policy settings without exposing secrets.

## Logging Helper
Use a single function for structured logging.

```powershell
function Write-AIAuditLog {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Result,
        [string]$Provider = "",
        [string]$Model = "",
        [string]$Endpoint = "",
        [string]$Message = ""
    )

    $dir = "$HOME\.ai-platform\logs"
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        user         = $env:USERNAME
        host         = $env:COMPUTERNAME
        action       = $Action
        result       = $Result
        provider     = $Provider
        model        = $Model
        endpoint     = $Endpoint
        message      = $Message
    }

    $path = Join-Path $dir ((Get-Date).ToString('yyyy-MM-dd') + '.jsonl')
    ($entry | ConvertTo-Json -Compress) | Add-Content -Path $path -Encoding utf8
}
```

## Policy Loader
```powershell
function Get-AIPolicy {
    $path = "$HOME\.ai-platform\policies\provider-policy.json"
    if (-not (Test-Path $path)) {
        throw "Provider policy file not found: $path"
    }
    return Get-Content $path -Raw | ConvertFrom-Json
}
```

## Secret Lookup
```powershell
function Get-AISecretValue {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $secret = Get-Secret -Vault AIVault -Name $Name -ErrorAction Stop
        if ($null -eq $secret -or [string]::IsNullOrWhiteSpace($secret.ToString())) { return $null }
        return $secret.ToString()
    } catch {
        return $null
    }
}
```

## Local Health Check
```powershell
function Test-OllamaPort {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        return $c.GetAsync("http://127.0.0.1:$Port/api/tags").Result.IsSuccessStatusCode
    } catch {
        return $false
    }
}
```

## Provider Selection Logic
```powershell
function Select-AIProvider {
    param([string]$RequestedModel)

    $policy = Get-AIPolicy
    $localPort = $null
    foreach ($p in @(12345,11434)) {
        if (Test-OllamaPort -Port $p) { $localPort = $p; break }
    }

    if ($localPort) {
        $model = if ($RequestedModel) { $RequestedModel } else { $policy.preferredLocalModel }
        return [pscustomobject]@{
            provider = 'ollama'
            model    = $model
            endpoint = "http://127.0.0.1:$localPort/v1"
            source   = 'local'
            reason   = 'Local provider available'
        }
    }

    if (-not $policy.cloudFallbackEnabled) {
        throw 'No local provider available and cloud fallback is disabled by policy.'
    }

    foreach ($name in $policy.cloudProviderPriority) {
        switch ($name) {
            'openrouter' {
                $key = Get-AISecretValue -Name 'OPENROUTER_API_KEY'
                if ($key) {
                    return [pscustomobject]@{
                        provider = 'openrouter'
                        model    = $policy.defaultCloudModels.openrouter
                        endpoint = 'https://openrouter.ai/api/v1'
                        source   = 'cloud'
                        reason   = 'Local unavailable; fallback allowed'
                    }
                }
            }
            'openai' {
                $key = Get-AISecretValue -Name 'OPENAI_API_KEY'
                if ($key) {
                    return [pscustomobject]@{
                        provider = 'openai'
                        model    = $policy.defaultCloudModels.openai
                        endpoint = 'https://api.openai.com/v1'
                        source   = 'cloud'
                        reason   = 'Local unavailable; fallback allowed'
                    }
                }
            }
            'anthropic' {
                $key = Get-AISecretValue -Name 'ANTHROPIC_API_KEY'
                if ($key) {
                    return [pscustomobject]@{
                        provider = 'anthropic'
                        model    = $policy.defaultCloudModels.anthropic
                        endpoint = 'https://api.anthropic.com'
                        source   = 'cloud'
                        reason   = 'Local unavailable; fallback allowed'
                    }
                }
            }
            'google' {
                $key = Get-AISecretValue -Name 'GOOGLE_API_KEY'
                if ($key) {
                    return [pscustomobject]@{
                        provider = 'google'
                        model    = $policy.defaultCloudModels.google
                        endpoint = 'https://generativelanguage.googleapis.com'
                        source   = 'cloud'
                        reason   = 'Local unavailable; fallback allowed'
                    }
                }
            }
            'azure-openai' {
                $key = Get-AISecretValue -Name 'AZURE_OPENAI_KEY'
                $url = Get-AISecretValue -Name 'AZURE_OPENAI_URL'
                if ($key -and $url) {
                    return [pscustomobject]@{
                        provider = 'azure-openai'
                        model    = $policy.defaultCloudModels.'azure-openai'
                        endpoint = $url
                        source   = 'cloud'
                        reason   = 'Local unavailable; fallback allowed'
                    }
                }
            }
        }
    }

    throw 'Cloud fallback enabled, but no configured provider secret is available.'
}
```

## Start Flow
### Sequence
1. Enforce PowerShell 7.
2. Load policy.
3. Detect running Ollama, or start it on loopback.
4. Select provider.
5. Export session environment variables for the selected provider.
6. Persist active state to JSON.
7. Write success log entry.

## Environment Mapping
- Ollama/local: `OPENAI_API_KEY=ollama`, `OPENAI_BASE_URL=http://127.0.0.1:<port>/v1`
- OpenRouter: `OPENAI_API_KEY=<vault key>`, `OPENAI_BASE_URL=https://openrouter.ai/api/v1`
- OpenAI: `OPENAI_API_KEY=<vault key>`, `OPENAI_BASE_URL=https://api.openai.com/v1`
- Anthropic/Google/Azure OpenAI: map values according to the tool you are launching; use adapter variables if the client is OpenAI-only.

## Audit Queries
Example helpers:
```powershell
function ai-audit-last {
    $path = Get-ChildItem "$HOME\.ai-platform\logs\*.jsonl" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($path) { Get-Content $path.FullName -Tail 20 }
}

function ai-provider {
    $path = "$HOME\.ai-platform\state\active-provider.json"
    if (Test-Path $path) { Get-Content $path -Raw }
    else { Write-Host 'No active provider state found.' -ForegroundColor Yellow }
}
```
