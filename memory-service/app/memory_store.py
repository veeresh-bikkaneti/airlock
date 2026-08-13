"""Long-term memory: a Chroma collection per project.

One collection per project (keyed by a hash of the project path) rather
than one global collection, so recall for project A never surfaces
memories written while working in project B.
"""
import hashlib
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import chromadb
from chromadb import EmbeddingFunction

from .config import CHROMA_DIR, EMBED_MODEL, load_memory_service_config
from .embeddings import OllamaEmbeddingFunction


def _collection_name(project_id: str) -> str:
    digest = hashlib.sha256(project_id.encode()).hexdigest()[:16]
    return f"project-{digest}"


def _git_head_sha(cwd: Optional[Path] = None) -> Optional[str]:
    """Best-effort `git rev-parse HEAD` against the repo the service is
    running in. Returns None (never raises) if git is unavailable or cwd
    isn't a git repo — freshness metadata degrades gracefully rather than
    breaking remember()/recall()."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def _commits_behind(old_sha: str, cwd: Optional[Path] = None) -> Optional[int]:
    try:
        result = subprocess.run(
            ["git", "rev-list", "--count", f"{old_sha}..HEAD"],
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


class MemoryStore:
    def __init__(
        self,
        embedding_function: Optional[EmbeddingFunction] = None,
        persist_dir=None,
        config_path: Optional[Path] = None,
    ):
        config = load_memory_service_config(config_path)
        self._top_k = config.get("topK", 3)
        self._similarity_threshold = config.get("similarityThreshold", 1.2)
        resolved_persist_dir = persist_dir or config.get("indexPath") or CHROMA_DIR
        self._client = chromadb.PersistentClient(path=str(resolved_persist_dir))
        self._embedding_function = embedding_function or OllamaEmbeddingFunction(
            model=config.get("embeddingModel") or EMBED_MODEL
        )
        # ponytail: freshness needs a git checkout to diff against. When this
        # service runs from the repo (dev/test), process cwd IS that checkout
        # and this is a non-issue. When deployed via setup.ps1's Copy-Item
        # into ~/.ai-platform/memory-service, that directory has no .git at
        # all — a plain file copy, not a clone — so cwd resolves to nothing
        # and _git_head_sha() returns None (freshness reports "unavailable",
        # not a crash and not a fabricated SHA). `projectPath` in
        # config/memory-service.json is the escape hatch: point it at the
        # real repo checkout to get real freshness numbers in deployed mode.
        # Upgrade path: have setup.ps1 persist $RepoDir into the deployed
        # copy so this doesn't need manual configuration.
        self._git_anchor = config.get("projectPath") or None

    def _collection(self, project_id: str):
        return self._client.get_or_create_collection(
            name=_collection_name(project_id),
            embedding_function=self._embedding_function,
        )

    def remember(self, project_id: str, text: str, metadata: Optional[dict] = None) -> str:
        collection = self._collection(project_id)
        doc_id = hashlib.sha256(f"{project_id}:{text}".encode()).hexdigest()
        full_metadata = dict(metadata or {"source": "memory-service"})
        # Chroma silently drops None-valued metadata keys on read, so a
        # missing commit SHA (git unavailable) is omitted rather than
        # written as an explicit None — recall()/freshness() already treat
        # a missing key the same way via .get(..., default=None).
        commit_sha = _git_head_sha(self._git_anchor)
        if commit_sha:
            full_metadata["indexed_commit_sha"] = commit_sha
        full_metadata["indexed_at"] = datetime.now(timezone.utc).isoformat()
        collection.upsert(
            ids=[doc_id],
            documents=[text],
            metadatas=[full_metadata],
        )
        return doc_id

    def recall(self, project_id: str, query: str, k: Optional[int] = None) -> list[dict]:
        collection = self._collection(project_id)
        count = collection.count()
        if count == 0:
            return []
        top_k = k if k is not None else self._top_k
        result = collection.query(query_texts=[query], n_results=min(top_k, count))
        hits = []
        for doc, meta, dist in zip(
            result["documents"][0], result["metadatas"][0], result["distances"][0]
        ):
            # Fail-closed: a chunk below the configured similarity threshold
            # (i.e. too dissimilar) is not attributable to the query, so it's
            # dropped rather than returned as if it were a real match (ADR-007).
            if dist > self._similarity_threshold:
                continue
            line_range = None
            if meta.get("start_line") is not None and meta.get("end_line") is not None:
                line_range = f"{meta['start_line']}-{meta['end_line']}"
            hits.append(
                {
                    "text": doc,
                    "metadata": meta,
                    "distance": dist,
                    "path": meta.get("path"),
                    "line_range": line_range,
                    "indexed_commit_sha": meta.get("indexed_commit_sha"),
                    "indexed_at": meta.get("indexed_at"),
                }
            )
        return hits

    def freshness(self, project_id: str) -> dict:
        """Staleness snapshot for ai-memory-status: the most-recently-written
        chunk's commit SHA / timestamp for this project, diffed against
        current HEAD. All fields are None if nothing has been indexed yet
        or git is unavailable."""
        collection = self._collection(project_id)
        # ponytail: full metadata scan to find the max indexed_at — fine at
        # interactive-command scale (this backs /health, polled by
        # ai-memory-status, not a hot path); add a max-timestamp index if a
        # project's collection ever grows large enough for this to matter.
        if collection.count() == 0:
            return {
                "indexed": False,
                "commitSha": None,
                "indexedAtUtc": None,
                "commitsBehind": None,
                "hoursSinceIndex": None,
            }
        got = collection.get(include=["metadatas"])
        metadatas = got.get("metadatas") or []
        indexed_ats = [m.get("indexed_at") for m in metadatas if m.get("indexed_at")]
        latest_at = max(indexed_ats) if indexed_ats else None
        latest_meta = next((m for m in metadatas if m.get("indexed_at") == latest_at), {})
        commit_sha = latest_meta.get("indexed_commit_sha")

        commits_behind = None
        if commit_sha:
            current_sha = _git_head_sha(self._git_anchor)
            if current_sha and current_sha != commit_sha:
                commits_behind = _commits_behind(commit_sha, self._git_anchor)
            elif current_sha == commit_sha:
                commits_behind = 0

        hours_since_index = None
        if latest_at:
            try:
                indexed_dt = datetime.fromisoformat(latest_at)
                hours_since_index = (datetime.now(timezone.utc) - indexed_dt).total_seconds() / 3600
            except ValueError:
                hours_since_index = None

        return {
            "indexed": True,
            "commitSha": commit_sha,
            "indexedAtUtc": latest_at,
            "commitsBehind": commits_behind,
            "hoursSinceIndex": hours_since_index,
        }
