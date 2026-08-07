"""Paths and constants shared across memory-service modules.

Mirrors the layout the rest of Airlock already uses under
$env:USERPROFILE\\.ai-platform (or $HOME/.ai-platform), so memory data
sits next to logs/ and state/ rather than inventing a new location.
AI_PLATFORM_DIR overrides the base dir — used by tests.
"""
import os
from pathlib import Path


def _platform_dir() -> Path:
    override = os.environ.get("AI_PLATFORM_DIR")
    if override:
        return Path(override)
    home = os.environ.get("USERPROFILE") or os.environ.get("HOME") or str(Path.home())
    return Path(home) / ".ai-platform"


PLATFORM_DIR = _platform_dir()
DATA_DIR = PLATFORM_DIR / "memory"
CHROMA_DIR = DATA_DIR / "chroma"
CHECKPOINT_DB = DATA_DIR / "checkpoints.sqlite"

ACTIVE_PORT_FILE = PLATFORM_DIR / ".active-port.json"
PROVIDER_POLICY_FILE = PLATFORM_DIR / "config" / "policies" / "provider-policy.json"

EMBED_MODEL = "nomic-embed-text"
