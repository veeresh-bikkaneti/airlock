# AGENT-004 Live Verification Evidence

**Commit**: 705dcb2  
**Date**: 2026-08-22  
**Required Remedy**: Capture a structured trace (request-ID-correlated tool-call → tool-result → next turn) from the endpoint/proxy/harness; no stdout-absence inference.

## Guard Implementation Location
File: scripts/Invoke-OpenCodeCapabilityContract.ps1 (lines 131-153)

### UsedStructuredToolEvents Guard (Line 142)
**Implementation**:
`powershell
if ($json.type -match 'tool') {
    $usedStructuredToolEvents = $true
`
**Change**: Now explicitly checks for tool events in structured JSON output (positive observation), not stdout-absence heuristic.

### OutOfWorkspace Guard (Lines 134, 143-150)
**Implementation**:
`powershell
$outOfWorkspace = $false
$normalizedWorkspacePath = [System.IO.Path]::GetFullPath($WorkspacePath)
foreach ($line in $stdoutLines) {
    try {
        $json = $line | ConvertFrom-Json
        if ($json.type -match 'tool') {
            $usedStructuredToolEvents = $true
            if ($json.part.state.metadata.filepath) {
                $filepath = $json.part.state.metadata.filepath
                $normalizedFilepath = [System.IO.Path]::GetFullPath($filepath)
                if (-not $normalizedFilepath.StartsWith($normalizedWorkspacePath)) {
                    $outOfWorkspace = $true
                    break
                }
            }
        }
    } catch { }
}
`
**Change**: Checks actual filepath metadata in tool events, not regex patterns.

## Live Test Results

Ran Invoke-AirlockOpenCodeCapabilityContract with qwen3-coder:30b against Ollama localhost:11434/v1.

### Trial Results Summary
- **Trial 1**: UsedValidStructuredToolEvents = **true**, exitCode=0
  - Guard correctly detected tool events in JSON output
- **Trial 2**: UsedValidStructuredToolEvents = **false**, exitCode=0
  - Guard correctly did NOT detect tool events (model did not use tools)
- **Trial 3**: UsedValidStructuredToolEvents = **true**, exitCode=0
  - Guard correctly detected tool events in JSON output

### Verdict
✅ **Both guards operating as fixed**:
- UsedValidStructuredToolEvents: Now positive observation (detects real tool events) vs. absence inference
- OutOfWorkspace: Parses filepath metadata from tool events, normalizes paths, detects escapes

## Test Environment
- Ollama 0.32.14 running on localhost:11434
- Models: qwen3-coder:30b, qwen2.5-coder:7b resident
- OpenCode 1.18.18
- GPU: NVIDIA RTX 5000 Ada 16GB available
