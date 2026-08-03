# Security Audit Runbook

## Security Goals
- Keep source code local by default.
- Prevent silent cloud failover.
- Protect credentials from source control and plain-text storage.
- Produce logs that support incident review and troubleshooting.

## Baseline Rules
- Use `pwsh` only.
- Bind local inference to `127.0.0.1`.
- Store credentials only in `AIVault`.
- Require human review for code changes.
- Disable automatic URL fetching where supported.
- Fail closed on missing policy or secret lookup failures.

## Audit Events To Capture
Record these events at minimum:
- Platform start.
- Ollama detected.
- Ollama launched.
- Provider selected.
- Cloud fallback invoked.
- Secret lookup failed.
- Tool session started.
- Tool session ended.
- Platform shutdown.
- User approval granted or denied.

## Approval Gates
### Require explicit user approval for
- Sending prompts or code to a cloud provider.
- Operating on repositories with regulated or sensitive data.
- Any action that writes credentials or modifies policy.
- Any bulk refactor across many files.

## Sensitive Data Policy
Never send these to cloud by default:
- API keys.
- Session cookies.
- Access tokens.
- Resume or identity documents.
- Customer data.
- Private source repositories unless policy explicitly permits it.

## Hardening Checklist
- Verify PowerShell major version equals 7.
- Verify Ollama endpoint is loopback-only.
- Verify `.env` ACL is restricted.
- Verify vault modules are installed.
- Verify `Get-SecretInfo` lists only expected keys.
- Verify git user identity is set.
- Verify `.gitignore` excludes local state and log files if needed.
- Verify aider or other tools do not auto-commit.
- Verify URL auto-detection is disabled if supported.
- Verify logs contain provider, model, and endpoint fields.

## Sample Review Procedure
1. Run `ai-start`.
2. Inspect current provider state.
3. Confirm provider is `ollama` unless you intentionally enabled cloud fallback.
4. Launch the coding tool.
5. Review diffs before accepting edits.
6. Review the latest audit log entries.
7. Run `ai-stop`.

## Failure Handling
### If local provider is down
- Log `WARNING` for local unavailability.
- If cloud fallback is disabled, stop and instruct the user to start or repair Ollama.
- If cloud fallback is enabled, log the fallback reason and selected cloud provider.

### If vault access fails
- Log `FAILED` for secret retrieval.
- Do not continue to cloud.
- Keep the session local-only or exit.

### If policy file is missing
- Stop immediately.
- Create an incident-style log entry.
- Do not infer permissive defaults.

## Example Incident Questions
- Did the session remain local throughout?
- If not, which provider received traffic?
- Was cloud usage explicitly allowed by policy?
- Was a secret read from vault at the time of fallback?
- Which model was active when code was generated?
