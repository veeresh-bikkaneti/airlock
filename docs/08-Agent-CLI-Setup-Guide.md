# Agent CLI Setup Guide

A step-by-step guide to connecting your favorite AI coding tool to Airlock. Every tool in this guide was actually run against a live Airlock instance while writing it, except one — GitHub Copilot CLI, flagged in its own section, since it isn't installed on the machine this was written on. Nothing here is copied from a vendor's docs and hoped to work. Where something doesn't work, that's stated plainly, with the reason and the actual error.

You don't need to read this front to back. Find your tool in the table of contents, follow its section, done.

## Contents

- [Before you start (read this once)](#before-you-start-read-this-once)
- [Pi.dev](#pidev)
- [opencode.ai](#opencodeai)
- [jcode](#jcode)
- [Codex CLI](#codex-cli-openais)
- [Claude Code](#claude-code)
- [aider](#aider)
- [GitHub Copilot CLI](#github-copilot-cli)
- [Gemini CLI](#gemini-cli-doesnt-work-yet)

## Before you start (read this once)

Every tool below needs three things from you:

1. **Airlock running.** Double-click `Start-AI.bat`, or run `.\scripts\Start-AI.ps1` — see [`07-Quickstart-Playbook.md`](07-Quickstart-Playbook.md) if you haven't done this yet. Leave that window open (or let it run in the background); if it's not running, every step below fails with a connection error, not a config error.
2. **The port it's listening on.** Default is `12345`. The startup script prints it (`Endpoint: http://127.0.0.1:12345/v1`) — if you changed it with `-Port`, use your number everywhere `12345` appears below.
3. **A model that's actually downloaded.** Run `ai-models` (or `ollama list`) to see what you have. `ai-start` auto-pulls a model sized to your hardware on first run, so you likely already have one — just make sure the name in your config matches something in that list. A config pointing at a model you haven't pulled yet will fail with a "model not found" error, which is easy to mistake for a setup mistake when it's really just a missing download.
4. **An honest sense of what a local model is for.** This platform gets you a real, working connection — that part is solved and tested per tool below. It does not turn a 7-30B local model into a frontier model. Every tested tool section below already notes where a small model connects fine but ignores instructions or hallucinates; that's a model-tier ceiling, not a wiring bug, and `config/models.json`'s `supportsFunctionCalling` flag tells you upfront which models can reliably drive tool calls at all (`false` on `deepseek-r1:14b` and the embedding model — don't point an agentic harness at those). Treat the local backend as strong for single-file edits, focused refactors, test generation, and explanation; treat "switch to local when the cloud limit hits" as a way to keep doing *that* kind of work, not as a drop-in continuation of large multi-step agentic work across an entire repo — [`09-Cross-Harness-Session-Resume.md`](09-Cross-Harness-Session-Resume.md) covers what actually carries over when you switch.

**One command to sanity-check the platform itself, before blaming any tool's config:**

```powershell
curl http://127.0.0.1:12345/v1/models
```

If that doesn't return a JSON list of model names, none of the tools below will work either — fix that first (usually: Airlock isn't running, or you used the wrong port).

Every "Verify it worked" step below asks the tool to reply with exactly the word `OK`. That's deliberate — it's the smallest possible proof that your prompt reached the model and a real answer came back, with nothing else to go wrong or misread.

---

## Pi.dev

**What it is:** a lightweight, extensible coding assistant CLI with built-in read/bash/edit/write tools.

**Setup:**

1. Copy the template into place:
   ```powershell
   Copy-Item config\pi-models.json.template "$env:USERPROFILE\.pi\agent\models.json"
   ```
   If that file already exists, open it instead and merge in the `ollama` block from the template — don't overwrite a config you already have other providers in.
2. Open the copied file and check the provider's `baseUrl` matches your port. ⚠️ **The provider key is `ollama`, not `ollama-local`** — an earlier draft of this doc got that wrong:
   ```json
   "ollama": {
     "baseUrl": "http://127.0.0.1:12345/v1",
     "apiKey": "ollama",
     "api": "openai-completions"
   }
   ```
3. **Check the port against what's actually running, every time — not just once.** Live-caught 2026-08-15: this config had `baseUrl` pointed at 11434, correct the last time someone checked, but `ai-start` had since started fresh on 12345 because nothing was already running to adopt. `pi -p "..."` failed with a plain `Connection error.` — no useful hint about why. Run `ai-port` and use that number.
4. Check the `models` array lists a model you've actually pulled (`ollama list`). The template ships with a few common picks — if none are in your list, add the one you do have.

**Verify the connection:**

```powershell
pi --provider ollama --model qwen2.5-coder:7b -p "Reply with exactly: OK"
```

Re-verified 2026-08-13 against the corrected template — `--provider ollama-local` in earlier versions of this doc was wrong; the config's actual top-level key is `ollama`, and pi will fail with `Unknown provider "ollama-local"` if you use the old name.

⚠️ **Run this from a repo with no `.ai-context/SESSION_STATE.md` present, or move that file aside first.** Pi reads repo files broadly as part of its own agentic context-gathering, and if that file exists (it will, after any prior Claude Code session in this repo — see ADR-004's "Known gap" section), its "conversation summary" field gets treated as ambient task content. Confirmed reproducible: with the file present, `qwen2.5-coder:7b` fabricated an unrelated file-edit tool call instead of replying `OK`; with the file moved aside, it replied correctly every time. This isn't a broken connection or a bad model — it's context bleed from an unrelated feature.

**Verify tool use separately — this is the part that actually matters for real work, and it does not behave the way you'd expect:**

```powershell
pi --provider ollama --model qwen2.5-coder:7b -p "Read cv.md and summarize it in 2 sentences."
```

**Tested live, 2026-08-15 — reproduced the same failure opencode has, on the same model:** tools are on by default in `-p` mode (confirmed by re-running with `--no-tools` and getting a different result), but instead of actually calling `read`, `qwen2.5-coder:7b` printed this as its entire response:

```json
{
  "name": "read",
  "arguments": {
    "path": "cv.md"
  }
}
```

That's the tool call as raw text, never executed. Identical failure shape to `qwen2.5-coder:7b`'s transcript in the opencode section below. Two independent harnesses, same Ollama model, same symptom — this isn't a Pi bug or an opencode bug, it's the underlying Ollama OpenAI-compat tool-calling layer.

**What actually works reliably: attach the file yourself instead of hoping the model asks for it.**

```powershell
pi --provider ollama --model qwen2.5-coder:7b -p "@cv.md" "Tell me in 2-3 sentences what role this person is targeting."
```

Tested live: clean, correct, specific answer — no hallucination, no drift. `@file` puts the content directly in context; the model never has to decide to call a tool at all. This is the same shape of fix as `ai-code`'s `--file` flag for aider (see below) — it's a real, general pattern for getting reliable results out of small local models, not specific to one tool.

**Troubleshooting:**
- Connection refused / plain "Connection error." → the port in `models.json` doesn't match what's actually running. Run `ai-port`, not the template's default.
- Model not found (from Ollama, not pi) → the model name in `models.json` isn't in `ai-models`. Pull it or pick one that's already local.
- Ignores your instruction entirely, talks about "session state" or "conversation summary" instead → see the `.ai-context/SESSION_STATE.md` warning above, not a model problem.
- Model claims it can't read files even though tools are enabled → don't ask it to decide; attach the file yourself with `@filename`.

---

## opencode.ai

**What it is:** a terminal-based coding agent with a TUI, built for working across many providers.

⚠️ **The config-file locations below were re-verified live against opencode 1.18.16 on 2026-08-15 and do not match what earlier drafts of this guide said.** If you set up opencode before that date, your config may be sitting in a file opencode no longer reads at all — see the real incident this section is based on in `docs/bugs-2/` if you want the full trace.

**Setup:**

`opencode --print-logs --log-level DEBUG` shows every config path it actually checks, in this exact order (later files override/merge over earlier ones):

1. `~/.config/opencode/config.json`, `opencode.json`, `opencode.jsonc`
2. `<project>/.opencode/opencode.json`, `.opencode/opencode.jsonc` — **not** a bare `opencode.json` in the repo root
3. `~/.opencode/opencode.json`, `~/.opencode/opencode.jsonc` — **this is the real global config path**, a different directory than `~/.config/opencode/`

Two real, independently-confirmed failure modes if you don't know this:
- A stale `~/.config/opencode/opencode.json` from some other setup (a different provider, a proxy, anything) sits there forever, silently overridden as long as one of the later files also sets `provider`/`model` — but the moment that later file goes missing, the stale config becomes live again with zero warning.
- Dropping the template at repo-root `opencode.json` (what earlier drafts of this doc said) does **nothing at all** — opencode 1.18.16 never reads that path.

Copy the template to the path that's actually load-bearing:

```powershell
Copy-Item config\opencode.json.template "$env:USERPROFILE\.opencode\opencode.json"   # global — real path
# — or, project-scoped —
New-Item -ItemType Directory -Force ".opencode" | Out-Null
Copy-Item config\opencode.json.template ".opencode\opencode.json"
```

**The template's `baseURL` port is a snapshot, not a guarantee — check it every time, not just once.** `Start-AI.ps1` scans for an *already-running* Ollama on port 11434 (Ollama's own default) before ever falling back to launching one fresh on 12345. If Ollama was already running (common — many installs auto-start it as a background service), `ai-start` silently adopts that port instead. Run `ai-port` and use *that* number, not whatever the template or an old config file says:

```powershell
ai-port    # prints the port actually in use right now
```

**Start the tool-call proxy: `ai-tool-proxy-start`.** The template points `provider.ollama.options.baseURL` at `http://127.0.0.1:12347/v1`, the proxy's port, not the port `ai-port` just showed you, because opencode drives Ollama's free-form tool-calling path, which reproducibly fails on `qwen2.5-coder:7b`/`qwen3-coder:30b` (the tool call comes back as plain text instead of a real `tool_calls` response, see the reproduced failure below). The proxy fixes this; without it running, opencode will connect but tool-using requests will misbehave. See [`README.md`'s Tool-Call Proxy section](../README.md#tool-call-proxy). The template defaults `model` to `ollama/devstral-small-2:24b`. Edit the model line if that's not what you have pulled.

**Also verify every model in your config's `models` list is actually pulled** (`ollama list`) — a config with an unpulled or misspelled tag fails per-model, not at config-load time, so it can look like the whole setup is broken when it's really just one bad tag.

**Verify it worked — port, model, and tool-calling separately, not just "did it reply":**

```powershell
opencode run "Reply with exactly: OK" --model ollama/qwen2.5-coder:7b
```

Tested live: returned `OK`, with `opencode` reporting the model it used (`qwen2.5:0.5b` in our test run) right above the answer, a handy way to confirm you're actually talking to the model you think you are. That confirms the connection and the model. It does **not** confirm tool-calling works — text-only replies take a different path than anything requiring a file read. Test that separately with a prompt that forces a real tool call:

```powershell
opencode run "Read cv.md and summarize the target role in 2 sentences." --model ollama/qwen2.5-coder:7b
```

**Tested live, 2026-08-15, both real failures reproduced before the fixes above, then a clean pass after:**
- Wrong port (config said 12345, live Ollama was on 11434): every request failed with `AI_APICallError: Cannot connect to API`, retried on a backoff that looks like a hang from the terminal, not an error.
- `qwen2.5-coder:7b`, once the port was fixed but before the tool-call proxy existed: the plain "reply OK" test passed clean. The file-read test did not — the model emitted the raw tool-call JSON as visible chat text (`{"name": "read", "arguments": {"filePath": "/path/to/cv.md"}}`) instead of it being executed, using a hallucinated placeholder path instead of the real one.
- `qwen3-coder:30b` (this platform's own "coding"-role model, same VRAM): the tool call itself was attempted, but with a malformed schema (missing the required argument), so it failed, and the agent's *recovery* from that failure is what actually broke: it hallucinated a tool that doesn't exist in opencode's toolset (`fetch`), then pivoted to a real tool (`webfetch`) but on a completely unrelated tangent, fetching public pages about AWS/EC2 documentation, nothing to do with the local CV file it was asked to read.

**This was not a config problem, and no template fix solved it: it needed a translation layer.** It's a reliability gap in Ollama's OpenAI-compatible tool-calling layer under an agentic harness that expects the tool-call contract to hold, confirmed on both a 7B and a 30B local model here, not a one-off. The [tool-call proxy](../README.md#tool-call-proxy) (`ai-tool-proxy-start`) fixes it by grammar-constraining Ollama's output instead of hoping the model's free-form template fires correctly. This matches the same Ollama compat-layer limitation already disclosed in `tools/airlock-manual/index.html`'s memory-service section (no prompt caching, ignored `tool_choice`) and in ADR-009, just confirmed here for opencode specifically.

**Troubleshooting:**
- `opencode` picks up the *global* config even when you meant project-scoped if you're not `cd`'d into the repo root when you run it.
- `opencode models` lists every provider/model opencode currently sees — run it any time you're not sure your config was picked up. Note it also lists opencode's own large built-in cloud-model catalog regardless of your config, so a model appearing in that list is **not** proof your local config loaded — check the debug log's `loading config from ...` lines for that.
- `opencode run ... --print-logs --log-level DEBUG` is the real diagnostic tool here — it shows every config path checked, which provider/model actually got selected, and the exact connection or schema error, instead of the terse top-level error opencode shows by default.
- Tool calls leaking into the chat response as raw JSON text: the tool-proxy isn't running, or the config still points at `12345` instead of `12347`. Run `ai-tool-proxy-status` to check.
- A silent multi-second pause before anything prints is opencode enumerating every installed skill across every skill-marketplace directory on the machine (`message=init count=<N>` in the debug log) — harmless, but if that count is in the thousands, it's adding real, avoidable startup latency; that's a housekeeping issue with the skill directories, not with Airlock.

---

## jcode

**What it is:** a coding agent CLI built around fast provider-switching (Claude Max, ChatGPT Pro, or any OpenAI-compatible endpoint).

**Setup:**

No template ships for jcode — you add a provider block directly with a CLI command instead of hand-editing TOML:

```powershell
jcode provider add local-ollama --base-url "http://127.0.0.1:12345/v1" `
  --model "qwen2.5-coder:7b" --provider ollama `
  --set-default --model-catalog --overwrite
```

- `--provider ollama` tells jcode this endpoint needs no API key — don't add `--auth` or `--no-api-key` flags, current jcode (v0.65.0+) doesn't have them.
- `--set-default` means jcode launches straight into this profile.
- `--model-catalog` means jcode fetches the live model list from `/v1/models`, so newly-pulled models show up in `jcode model list` without re-running this command.

This writes into `%USERPROFILE%\.jcode\config.toml` — jcode has no per-project config, this is a one-time, machine-wide setup.

**Verify it worked:**

```powershell
jcode run --provider-profile local-ollama -m qwen2.5-coder:7b "Reply with exactly: OK"
```

Tested live: returned `OK`, plus a token-usage line jcode prints after every response.

**Troubleshooting:**
- `jcode provider-doctor` walks every stage of the connection (catalog, model-switch, chat, streaming, tools) and tells you exactly which one is broken — reach for this before re-reading your config by eye.

---

## Codex CLI (OpenAI's)

**What it is:** OpenAI's coding agent CLI.

**One thing that trips people up:** Codex only speaks OpenAI's newer *Responses* API (`wire_api = "responses"`) — the older *Chat Completions* shape (`wire_api = "chat"`) is flatly rejected by the CLI itself ("no longer supported"). Airlock's Ollama backend answers Responses-API requests too (confirmed live, on this exact instance), so this works — but only because of that. If you're on an older Ollama version, check with `curl http://127.0.0.1:12345/v1/responses -d '{"model":"<any pulled model>","input":"hi"}'` first; a `404` means upgrade Ollama before continuing.

**Setup:**

No template ships for Codex either — it has no per-project config file to copy, everything lives in `%USERPROFILE%\.codex\config.toml`. Add this block (don't delete anything already in that file — TOML files can hold multiple provider blocks side by side):

```toml
[model_providers.airlock]
name = "airlock"
base_url = "http://127.0.0.1:12345/v1"
wire_api = "responses"

model_provider = "airlock"
model = "qwen2.5-coder:7b"
```

The last two lines (`model_provider`, `model`) are top-level keys, not part of the `[model_providers.airlock]` table — if you're pasting this into a file that already has other top-level keys, keep them grouped together, before any `[table]` headers, or TOML will refuse to parse the file.

**Verify it worked:**

```powershell
echo "Reply with exactly: OK" | codex exec
```

Tested live against the platform's actual `12345` endpoint: ran this twice back to back. First run returned `OK` cleanly. Second run, same command, same model, came back with a confused reply about an unsupported `rtk` command and a router error in the logs — the connection itself was fine both times (real round trip, real token counts, no connection error), the *model* just isn't reliable. We're testing with `qwen2.5:0.5b`, a tiny model chosen for speed, not quality — **don't read the connectivity result as a verdict on the model.** Use `qwen2.5-coder:7b` or bigger for actual work; the config above already defaults to it.

**Troubleshooting:**
- Codex's own `--oss --local-provider ollama` flag exists and looks tempting, but it hard-codes Ollama's *default* port (`11434`), not Airlock's (`12345`). Use the config above instead unless you've deliberately run Ollama on its default port outside Airlock.
- Getting a coherent-looking but wrong answer rather than a connection error? That's model quality, not setup — see above.

---

## Claude Code

**What it is:** this tool — Anthropic's coding agent CLI, running in your terminal.

**One thing that trips people up:** Claude Code only speaks Anthropic's *Messages* API (`/v1/messages`), never the OpenAI-style Chat Completions endpoint most other tools on this page use. Airlock's Ollama backend answers Messages-API requests too (confirmed live), which is what makes this work at all — it's not a documented Ollama feature, just a real one on the version installed here. If your Ollama is old enough not to have it, this section won't work; the `/v1/responses` check in the Codex section above (same idea, different route) tells you if you're affected.

**Setup:**

**Recommended — session-scoped, verified against a live endpoint before it's set, cleared automatically on `ai-stop`:**

```powershell
ai-claude-on    # checks the platform is actually listening first, then redirects this shell only
claude -p "Reply with exactly: OK"
ai-claude-off   # or just close the shell — the redirect never outlives it either way
```

**Alternative — permanent, via `settings.json`'s `env` block.** Add this to your Claude Code `settings.json` (`~/.claude/settings.json` for your whole user, or `.claude/settings.json` in a specific project):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:12345",
    "ANTHROPIC_AUTH_TOKEN": "ollama"
  }
}
```

`ANTHROPIC_AUTH_TOKEN` can be any non-empty string — Ollama doesn't check it, it just needs to see *something* there. Use `ANTHROPIC_AUTH_TOKEN`, not `ANTHROPIC_API_KEY`: per [Anthropic's authentication docs](https://code.claude.com/docs/en/authentication), `AUTH_TOKEN` is the documented variable for gateway/proxy routing and outranks `API_KEY` in precedence, while `API_KEY` is for direct Anthropic API access and, in interactive sessions, needs a one-time approval that a previously-declined key silently skips. This repo used to ship a `claude-settings.json.template` that invented a different, fake settings schema; it's been deleted. The `env` block above is the real one.

⚠️ **Know the tradeoff before you use this route.** Unlike `ai-claude-on`, this block has no liveness check and no off switch — it applies to *every* Claude Code session on the machine, including ones with nothing to do with this platform, and it stays in effect after `ai-stop`, a reboot, or a port change, until you remove it by hand. See the troubleshooting entry below for what that looks like when it goes wrong.

**Verify it worked:**

```powershell
$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:12345"
$env:ANTHROPIC_AUTH_TOKEN = "ollama"
$env:ANTHROPIC_MODEL = "qwen2.5-coder:7b"
claude -p "Reply with exactly: OK"
```

Tested live against the platform's actual `12345` endpoint, with an honest caveat: this setup connects and gets real answers back — confirmed (twice, in two separate test sessions, same result both times). What we tested with, though, was a tiny 0.5B-parameter model, and both times it **ignored the instruction** — once rambling, once inventing a fake tool call instead of just replying `OK`. That's not a connection failure (no error, no timeout, a real response came back each time) — it's a model-quality problem: Claude Code's system prompt is long and its agentic loop expects a genuinely capable instruction-following model. **Use a real coding model here** — `qwen2.5-coder:7b` or bigger, the same tier Airlock already auto-selects for you — not whatever's smallest and fastest to test with.

**Troubleshooting:**

#### "Connection refused — a firewall or proxy may be blocking it"

This is not a firewall or proxy issue, whatever the message implies. It means `ANTHROPIC_BASE_URL` is pointing at a local port with nothing listening — almost always the `env` block above, left set after the platform stopped. It disables Claude Code for *every* project, including ones that never touch this platform, and it survives `settings.json` edits, terminal restarts, and Claude Code reinstalls if it was set at Windows User scope.

Diagnose and fix in one step:
```powershell
ai-doctor
```

Or manually:
```powershell
Get-ChildItem Env: | Where-Object { $_.Name -match 'ANTHROPIC' }
[Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL','User')
Remove-Item Env:\ANTHROPIC_BASE_URL, Env:\ANTHROPIC_AUTH_TOKEN, Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
[Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL',   $null, 'User')
[Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $null, 'User')
[Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY',    $null, 'User')
```

Also check the project-local file — it's easy to miss and holds its own separate copy:
```powershell
Get-Content .\.claude\settings.local.json
```

Then **restart every open shell and every running Claude Code process** — both hold a stale copy of the environment and keep failing until relaunched, even after the fix above.

- Getting the base-url/auth-token error this section exists to prevent, but not the "firewall or proxy" one above? Double check you're editing `settings.json`'s `env` block correctly, not a shell-only `$env:ANTHROPIC_BASE_URL` that gets lost the next time you open Claude Code from your editor or a shortcut — `ai-claude-on` avoids this class of mistake entirely.
- This platform's own cloud fallback (`ai-auth-set anthropic <key>` + `cloudFallbackEnabled: true` in `provider-policy.json`) is a separate thing — that's Airlock optionally calling out to Anthropic's real API for genuine Claude models, unrelated to pointing Claude Code itself at your local models.

---

## aider

**What it is:** a mature, git-native AI pair-programming CLI.

**Setup:**

Aider reads its settings from `~/.aider.conf.yml` — that's the file to create or edit, not CLI flags (flags work too, but the config file is what the repo's own `ai-code` helper relies on):

```yaml
model: openai/qwen2.5-coder:7b
openai-api-base: http://127.0.0.1:12345/v1
openai-api-key: ollama
auto-commits: false
```

The `openai/` prefix on the model name tells aider (built on LiteLLM) to use the generic OpenAI-compatible path instead of trying to match the name against OpenAI's own hosted model list.

Once that file exists, the repo's own `ai-code` helper (in `scripts/profile-helpers.ps1`) launches aider with the right model already selected:

```powershell
ai-code
```

**Verify it worked:**

```powershell
aider --model openai/qwen2.5-coder:7b --message "Reply with exactly: OK" --yes-always
```

Tested live: this returned `OK` — but not on the first try. **The first attempt failed with a wall of `litellm.InternalServerError: Connection error` retries, even though the platform was confirmed healthy at the same time via a plain `curl` to the same endpoint.** The cause: this machine had `OPENAI_API_BASE` and `OPENAI_BASE_URL` environment variables already set (by an unrelated tool, pointed at a different local port with nothing listening on it) — LiteLLM reads those and **silently overrides both the `--openai-api-base` flag and the `.aider.conf.yml` setting**, with no warning that it's doing so. Clearing them fixed it immediately:

```powershell
# check first:
echo $env:OPENAI_API_BASE
echo $env:OPENAI_BASE_URL
# if either is set to something that isn't Airlock's URL, clear it before running aider:
Remove-Item Env:\OPENAI_API_BASE -ErrorAction SilentlyContinue
Remove-Item Env:\OPENAI_BASE_URL -ErrorAction SilentlyContinue
```

If you use other AI CLIs or proxies that set these globally in your shell profile, aider will always lose to them silently — this is the single most likely reason aider "doesn't work" even when your config file is completely correct.

**Troubleshooting:**
- **Connection errors despite a healthy platform** → see the environment variable conflict above. Check `OPENAI_API_BASE`/`OPENAI_BASE_URL` before anything else.
- `--yes-always` skips aider's confirmation prompts — useful for one-shot testing like above, but for real work you probably want to leave confirmations on so aider asks before touching files.
- First run against a big repo is slower (building the repo map, ~a few seconds here on a 119-file repo). Subsequent runs are faster — aider caches it.

---

## GitHub Copilot CLI

**What it is:** GitHub's coding agent CLI, `copilot`.

**Not installed on the machine this guide was written on**, so unlike every section above, this one wasn't tested end-to-end here — install it yourself if you want to (`npm install -g @github/copilot`, or see [GitHub's install docs](https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli)) and the steps below should work, since they come straight from GitHub's own documentation rather than a guess.

**Setup:**

Copilot CLI added support for custom/local model providers in April 2026. Set these environment variables before launching it — no config file, just env vars in your current shell:

```powershell
$env:COPILOT_PROVIDER_BASE_URL = "http://127.0.0.1:12345/v1"
$env:COPILOT_MODEL = "qwen2.5-coder:7b"
copilot
```

- `COPILOT_PROVIDER_TYPE` defaults to `openai`, which is what Ollama speaks — you don't need to set it.
- `COPILOT_PROVIDER_API_KEY` isn't needed for a local, unauthenticated endpoint like this one.
- GitHub's docs say your model needs to support **tool calling** and **streaming** — `qwen2.5-coder` supports both. They also recommend a 128k+ context window model for best results.

**Verify it worked:** ask it something in the interactive session, or check GitHub's docs for a non-interactive flag if you want a scripted version like the other sections above.

---

## Gemini CLI (doesn't work yet)

**What it is:** Google's `gemini` CLI.

**Short answer: no, and there's currently no config that fixes it.** This was tested, not assumed — the two paths that might plausibly work were checked and ruled out:

1. **`GOOGLE_GEMINI_BASE_URL`** — an environment variable that does redirect Gemini CLI's requests to a different host. We actually ran it pointed at the platform (`GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:12345 gemini --skip-trust -p "..."`) rather than assuming — it fails with `ModelNotFoundError: 404 page not found`. Reason: the CLI still sends Google's own Gemini wire format to that host, and Airlock's Ollama backend doesn't speak it (also checked directly — no `generateContent` or `v1beta`-style routes exist anywhere in the installed Ollama binary, only the OpenAI and Anthropic ones the sections above use). Both checks agree: real 404 in practice, and no matching route in the binary to explain why.
2. **`gemini gemma`** — a built-in subcommand for running a local model. This looked promising by name, but it's a *different* local-model path entirely: it downloads Google's own Gemma model and runs it through Google's own LiteRT-LM runtime, with no way to point it at Airlock or any other OpenAI-compatible server instead.

If you specifically want Gemini CLI's interface pointed at local/Ollama models, there are community forks that add real OpenAI-compatible routing (`ollama-code`, `open-gemini-cli` are two) — but that's a different tool than the official `gemini` CLI this section covers, and outside what this guide sets up.
