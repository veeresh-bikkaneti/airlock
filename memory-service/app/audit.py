"""Structured audit logging, same JSONL shape/location the PowerShell scripts
already write to ($PlatformDir/logs/<date>.jsonl) — so ai-audit-last shows
memory-service events alongside everything else, not a second silo.
"""
import json
import os
import socket
from datetime import datetime, timezone

from .config import PLATFORM_DIR

LOG_DIR = PLATFORM_DIR / "logs"


def write_audit_log(
    action: str,
    result: str,
    message: str = "",
    detail: str = "",
    provider: str = "memory-service",
    model: str = "",
    endpoint: str = "",
) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_file = LOG_DIR / f"{datetime.now().strftime('%Y-%m-%d')}.jsonl"
    entry = {
        "timestampUtc": datetime.now(timezone.utc).isoformat(),
        "user": os.environ.get("USERNAME") or os.environ.get("USER") or "",
        "host": socket.gethostname(),
        "action": action,
        "result": result,
        "provider": provider,
        "model": model,
        "endpoint": endpoint,
        "message": message,
        "detail": detail,
    }
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")
