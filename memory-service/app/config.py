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
# PENDING item 9: a separate Chroma store for coding-path memories, keyed by
# a different embedding model (EmbeddingGemma-300M via llama.cpp) than the
# chat path's (nomic-embed-text via Ollama). Chroma binds one embedding
# function per collection at creation time and the two models have
# different vector dimensions - sharing CHROMA_DIR would risk a dimension
# mismatch if a project_id ever collided between chat and coding use.
CHROMA_DIR_CODING = DATA_DIR / "chroma-coding"
CHECKPOINT_DB = DATA_DIR / "checkpoints.sqlite"

ACTIVE_PORT_FILE = PLATFORM_DIR / ".active-port.json"
PROVIDER_POLICY_FILE = PLATFORM_DIR / "config" / "policies" / "provider-policy.json"

# Deliberately separate from ACTIVE_PORT_FILE, not a shared/overwritten path:
# ACTIVE_PORT_FILE is the chat path's (ai-start's) own state, read by
# Stop-AI.ps1 to know what to stop. Coding sessions (ai-agent-start) run a
# different backend (llama.cpp) on a dynamic port and must never overwrite
# that file - a coding session could otherwise get the chat backend killed
# by a chat-path stop, or vice versa. See docs/adr/PENDING.md item 9.
ACTIVE_PORT_FILE_CODING = PLATFORM_DIR / ".active-port-coding.json"

# PENDING item 9: dedicated embedding runtime (a second, separate
# llama-server process running EmbeddingGemma-300M, --embedding mode) real
# memory for the coding path needs, since llama.cpp's coding-model server
# doesn't serve Ollama's /api/embeddings route. Written by
# Start-AirlockEmbeddingRuntimeIfNeeded (llamacpp.ps1), read here.
ACTIVE_PORT_FILE_EMBEDDING = PLATFORM_DIR / "state" / "llamacpp-embedding-instance.json"

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
