# airlock-worker:latest — ADR-012 §9.2 "Job-manifest worker" (Phase F)
# Minimal image for the locked-down, non-admin, ephemeral container that
# Start-AgentWorkerJob.ps1 launches (scripts/agent-job-helpers.ps1's
# Build-AirlockWorkerDockerArgs). Only needs what a job's allowedCommands
# examples in the ADR actually run: git (diff/status) and a Node/pnpm
# toolchain (pnpm test/lint). node:24-bookworm-slim already ships a uid
# 1000 "node" user, matching Build-AirlockWorkerDockerArgs's fixed
# --user 1000:1000 (no useradd needed - reuse what the base image gives).
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates git ripgrep curl jq python3 \
    && rm -rf /var/lib/apt/lists/*

# corepack's shim still calls out to the npm registry to resolve "latest"
# on every invocation unless a project's package.json pins a version -
# confirmed live: EAI_AGAIN against registry.npmjs.org under this job
# container's --network none, even after `corepack prepare --activate`.
# A plain global npm install has no such runtime resolution step.
RUN npm install -g pnpm@9

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace

# --user 1000:1000 is supplied at `docker run` time by
# Build-AirlockWorkerDockerArgs, not fixed here.
ENTRYPOINT ["/entrypoint.sh"]
