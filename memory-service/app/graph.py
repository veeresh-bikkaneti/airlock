"""LangGraph orchestration: retrieve (long-term recall) -> inject -> forward.

The checkpointer passed to .compile() handles persistence automatically —
every node execution is auto-saved against the thread_id in the invoke
config, which is what gives short-term/working memory continuity across
separate HTTP requests.
"""
from typing import Annotated, Callable, TypedDict

from langgraph.graph import END, StateGraph
from langgraph.graph.message import add_messages

from .memory_store import MemoryStore

ROLE_BY_MESSAGE_TYPE = {"human": "user", "ai": "assistant", "system": "system"}


class ChatState(TypedDict):
    project_id: str
    messages: Annotated[list, add_messages]
    retrieved: list[str]


def to_openai_messages(messages: list) -> list[dict]:
    return [{"role": ROLE_BY_MESSAGE_TYPE.get(m.type, m.type), "content": m.content} for m in messages]


def build_graph(memory_store: MemoryStore, forward_fn: Callable[[list[dict]], dict]) -> StateGraph:
    """forward_fn receives OpenAI-style messages, returns {"role": "assistant", "content": ...}."""

    def retrieve(state: ChatState) -> dict:
        last_human = next((m for m in reversed(state["messages"]) if m.type == "human"), None)
        if last_human is None:
            return {"retrieved": []}
        hits = memory_store.recall(state["project_id"], last_human.content, k=3)
        return {"retrieved": [h["text"] for h in hits]}

    def inject_and_forward(state: ChatState) -> dict:
        messages = to_openai_messages(state["messages"])
        if state.get("retrieved"):
            context = "\n".join(f"- {r}" for r in state["retrieved"])
            messages = [{"role": "system", "content": f"Relevant memory:\n{context}"}] + messages
        reply = forward_fn(messages)
        return {"messages": [reply]}

    graph = StateGraph(ChatState)
    graph.add_node("retrieve", retrieve)
    graph.add_node("forward", inject_and_forward)
    graph.set_entry_point("retrieve")
    graph.add_edge("retrieve", "forward")
    graph.add_edge("forward", END)
    return graph
