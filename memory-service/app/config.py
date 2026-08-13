"""Paths and constants shared across memory-service modules.

Mirrors the layout the rest of Airlock already uses under
$env:USERPROFILE\\.ai-platform (or $HOME/.ai-platform), so memory data
sits next to logs/ and state/ rather than inventing a new location.
AI_PLATFORM_DIR overrides the base dir — used by tests.
"""
import json
import os
from pathlib import Path
from typing import Optional


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

# ADR-007: repo-root config/memory-service.json declares retrieval governance
# (embedding model, vector store, index path, chunking, topK, similarity
# threshold) instead of leaving those as hardcoded constructor defaults.
# Resolved via __file__, not cwd, so it works regardless of where the
# service process (or a test) is launched from.
REPO_ROOT = Path(__file__).resolve().parents[2]
MEMORY_SERVICE_CONFIG_FILE = REPO_ROOT / "config" / "memory-service.json"


def load_memory_service_config(path: Optional[Path] = None) -> dict:
    """Read config/memory-service.json. `indexPath` is `~`-expanded here so
    callers get a ready-to-use path string."""
    cfg_path = Path(path) if path else MEMORY_SERVICE_CONFIG_FILE
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    if cfg.get("indexPath"):
        cfg["indexPath"] = os.path.expanduser(cfg["indexPath"])
    return cfg
