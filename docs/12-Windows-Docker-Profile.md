# Windows Docker Profile

This is Airlock’s preferred reproducible execution profile for Windows. It uses **Docker Desktop with the WSL2/Linux-container engine** for the agent worker and Hermes/OpenClaw-style harness isolation. Model inference remains governed by Airlock’s machine-specific runtime certificate; Docker does not make an unsupported model or GPU configuration safe automatically.

## Why Docker is the default Windows profile

Docker provides a repeatable Linux userland, explicit mounts, bounded CPU/RAM, dropped capabilities, read-only container roots, and a clear network policy. WSL2 is the recommended Docker Desktop backend because it is the supported path for Linux containers on Windows and provides a consistent environment across Windows installations.

Airlock still keeps a PowerShell-only fallback for chat and for machines where Docker Desktop cannot be installed. The fallback is less reproducible and does not replace the Docker security boundary for autonomous worker jobs.

## Prerequisites

The supported Windows Docker baseline is:

| Requirement | Check | Required behavior |
|---|---|---|
| Windows 10/11 Pro or Enterprise | `winver` | Windows Sandbox and Docker Desktop features are available. Home may work with Docker Desktop, but is not the evidence target. |
| PowerShell 7 | `$PSVersionTable.PSVersion` | Required by Airlock entrypoints. |
| Git | `git --version` | Required by the bootstrap and isolated worktrees. |
| Docker Desktop | `docker version` | Docker client and daemon must both respond. |
| Linux containers / WSL2 engine | `docker info --format '{{.OSType}}'` | Must print `linux`. Windows containers are rejected. |
| Compose v2 | `docker compose version` | Required by the Hermes launcher. |
| NVIDIA GPU, if present | `nvidia-smi` | Used for sizing only; GPU access must be proven separately. |

## Bootstrap

From a clean Windows PowerShell 5.1 or PowerShell 7 shell:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
irm https://raw.githubusercontent.com/veeresh-bikkaneti/airlock/main/install.ps1 | iex
```

The installer deploys Airlock’s PowerShell control plane. It does not silently install Docker Desktop or a 13–23 GB model. Those are privileged/large operations and must be visible to the operator.

## Docker preflight

Run this before attempting a worker or Hermes session:

```powershell
$ErrorActionPreference = 'Stop'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop is not installed or docker is not on PATH.' }
docker info | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop is installed but the daemon is not running.' }
$os = (docker info --format '{{.OSType}}').Trim()
if ($os -ne 'linux') { throw "Airlock requires Docker Desktop Linux/WSL2 containers; Docker server OS was '$os'." }
docker compose version
```

The Hermes launcher performs the same checks automatically. It rejects a stopped daemon, Windows-container mode, or missing Compose v2 before consuming a capability certificate or building an image.

## Coding path

The coding path is intentionally evidence-gated:

```powershell
ai-agent-start -Harness pi-worker
```

Airlock then:

1. inspects this machine’s available VRAM and RAM;
2. selects a fitting coding profile or CPU/RAM fallback;
3. acquires the exact GGUF artifact when permitted;
4. starts the selected runtime;
5. runs a live structured tool-call contract through the selected harness;
6. measures throughput;
7. publishes a certificate bound to the model digest, runtime, harness, and current machine.

A Docker worker is not allowed to run without a fresh passing certificate:

```powershell
.\scripts\New-AgentJobManifest.ps1 -Task "Add a small test" -RepoPath "C:\src\scratch"
.\scripts\Start-AgentWorkerJob.ps1 -JobId <id> -WhatIf
.\scripts\Start-AgentWorkerJob.ps1 -JobId <id>
```

The worker receives only its isolated worktree and a read-only policy file. It has no host-home mount, Docker socket, browser session, credentials, implicit host PID namespace, or automatic merge/push authority.

## Hermes/OpenClaw-style container landing

After a valid Pi-compatible certificate exists:

```powershell
cd .\hermes-container
.\run-hermes.ps1 -CareerOpsRepo C:\src\scratch
```

The launcher verifies Docker Desktop Linux/WSL2 mode and Compose v2, consumes only the endpoint/model proven by the certificate, mounts the repository read-only, and writes generated output to a Docker volume.

## Edge0 assessment

[Edge0](https://github.com/Edge0-AI/Edge0) is a valuable reference for backend isolation and SSD/expert-offload design, but it is not currently a Windows solution. Its official documentation states:

> The MLX backend currently runs on Apple Silicon; the CUDA backend is on the roadmap; no other platforms are supported yet.

Airlock should borrow Edge0’s **backend facade** idea if it later adds an Apple-Silicon or streaming-MoE adapter, but it should not make Edge0 a Windows dependency or claim that Edge0 provides CUDA/Windows support today.

## What is proven by this profile

This profile can provide a reproducible Windows Docker boundary and honest machine-specific coding evidence. It does **not** prove that every Windows computer can run the same model. The model/quantization decision remains hardware-specific:

- GPU-fit models are preferred for interactive speed;
- CPU/RAM mmap is allowed when the artifact fits and is labeled slow;
- machines that cannot fit even the smallest supported artifact receive a clear refusal or chat-only fallback;
- no certificate is copied from another machine.

## Required live acceptance evidence

A Windows release candidate must attach evidence for:

- clean Windows Sandbox install;
- Docker Desktop Linux/WSL2 preflight;
- llama-server acquisition or PATH resolution;
- at least one GPU-fit coding run;
- at least one CPU/RAM fallback run on a smaller machine;
- structured tool events, not narrated JSON;
- measured throughput and model digest;
- worker `-WhatIf` no-side-effect behavior;
- real worker output as an unmerged patch;
- Hermes/OpenClaw landing and reversible configuration rollback.

Until those checks are recorded, Airlock should be described as **Windows Docker-ready**, not universally production-proven.
