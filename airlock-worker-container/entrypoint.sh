#!/bin/bash
# airlock-worker entrypoint — ADR-012 §9.2.
# ponytail: this is a stub, not a task-execution agent. It proves the
# container boots read-only/non-root/network-disabled against a mounted
# job worktree and read-only policy file, and exits cleanly - closing the
# "image not found" gap (Phase F). Wiring an actual agent loop that reads
# /policy/job-policy.json's allowedCommands and executes the manifest's
# task is a separate, much bigger piece of work; add it there when that
# lands.
set -euo pipefail

# --read-only leaves $HOME (/home/node) unwritable, so a plain
# `git config --global` fails with "Read-only file system" (confirmed live)
# - point HOME at the one writable path this container has, --tmpfs /tmp,
# so the safe.directory write below actually lands.
export HOME=/tmp

# The bind-mounted /workspace is owned by the host, not this container's
# uid 1000 - git's dubious-ownership check would otherwise refuse every
# git command below. Safe here: this container never leaves its own
# ephemeral, --network none sandbox.
git config --global --add safe.directory /workspace 2>/dev/null || true

echo "airlock-worker starting."
echo "  workspace: /workspace"
echo "  policy:    ${AIRLOCK_POLICY_FILE:-<none>}"
echo "  bounds:    ${AIRLOCK_MAX_WALL_CLOCK_MINUTES:-?}min / ${AIRLOCK_MAX_TOOL_STEPS:-?} tool steps"

if [ -n "${AIRLOCK_POLICY_FILE:-}" ] && [ -f "${AIRLOCK_POLICY_FILE}" ]; then
    echo "  job policy contents:"
    cat "$AIRLOCK_POLICY_FILE"
fi

echo "No task-execution agent is wired into this image yet - nothing in the workspace was changed."
exit 0
