# Airlock: Local AI, Zero Drama

Let's be honest: setting up local AI on Windows usually means three Ollama instances fighting over your VRAM, a port nobody remembers, and a firewall rule you *swear* you added. We've all been there. Airlock is our attempt to make that mess disappear — one script, one door, one stable endpoint.

We're gonna make you an offer you can't refuse: run this —

```powershell
irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex
```

— and Airlock sniffs your hardware, installs Ollama if it's missing, picks a model that actually fits your RAM/VRAM, and hands you one endpoint: `http://127.0.0.1:12345/v1`. No manual `ollama pull`, no juggling env vars, no second install because the first one "felt off."

**Security isn't an afterthought here, it's the whole point.** Binds to `127.0.0.1` only. Single instance, enforced. Every action audit-logged. And at the Windows Firewall, inbound traffic to that port meets its Gandalf moment: **"You shall not pass!"** Cloud fallback exists, but only if *you* opt in with *your* key — this is your machine, your rules, your business, nobody else's.

Compare that to renting a bigger cloud subscription every time your context window gets hungry. Turns out — you don't need a bigger boat.

We didn't just write docs and hope — we actually plugged Airlock into real coding tools and watched the round trips happen: Pi.dev, opencode.ai, jcode, Codex CLI, Claude Code, and aider all work, verified end to end. We'll even tell you what *doesn't* work (Gemini CLI — speaks a different wire protocol, 404s every time) because the first rule of Airlock club is: we log everything, so naturally, we talk about it.

Here's the part that surprised even us: switch from Claude Code to Grok CLI, Pi CLI, or OpenCode mid-task, and you don't have to re-explain yourself. One markdown snapshot, `.ai-context/SESSION_STATE.md`, gets written when a Claude Code session ends and read back by whichever tool you open next — branch, last commit, changed files, what you were just talking about. Pi CLI proved it end-to-end with a real model reply, not just config loading; the others we verified as far as each tool's own limits allow, and we say exactly where those limits are instead of rounding up. No new database, no daemon — just a file every LLM in the building already knows how to read.

There's also a 3D system visualizer for watching your architecture breathe, and a sandboxed "Hermes" agent on deck for job-hunting tasks (still on our own to-do list to put through its paces — more on that soon).

One door. Open when you need it. Locked to everyone else. Come on in.
