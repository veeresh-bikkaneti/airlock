"""Short-term + working memory: one LangGraph SqliteSaver checkpointer.

In practice "immediate conversation context" (short-term) and "current task
state" (working memory) are the same graph state in LangGraph, keyed by
thread_id (= session id) — so this is deliberately one store, not two.
"""
import sqlite3
from pathlib import Path
from typing import Optional

from langgraph.checkpoint.sqlite import SqliteSaver

from .config import CHECKPOINT_DB


def get_checkpointer(db_path: Optional[Path] = None) -> SqliteSaver:
    path = Path(db_path or CHECKPOINT_DB)
    path.parent.mkdir(parents=True, exist_ok=True)
    # check_same_thread=False: FastAPI runs sync routes in a threadpool, so
    # requests for the same session can legitimately land on different
    # threads. SqliteSaver serializes access internally.
    conn = sqlite3.connect(str(path), check_same_thread=False)
    return SqliteSaver(conn)
