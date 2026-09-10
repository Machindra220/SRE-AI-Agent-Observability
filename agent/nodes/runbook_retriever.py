# =============================================================
# agent/nodes/runbook_retriever.py
# Node 2 — Retrieves the most relevant runbook via RAG.
#
# Input:  state["search_query"]
# Output: state["runbook_context"], state["runbook_source"]
#
# Why this exists:
#   Grounds the LLM in real runbook content so it doesn't
#   hallucinate. This is the retrieval step of RAG.
# =============================================================

import logging
from agent.state import AgentState
from rag.retriever import retrieve

logger = logging.getLogger(__name__)

# Minimum similarity score to consider a runbook match valid.
# Below this threshold, we warn that retrieval quality is low.
MIN_SIMILARITY_THRESHOLD = 0.50


def retrieve_runbook(state: AgentState) -> AgentState:
    """
    LangGraph Node 2 — Runbook Retriever.

    Reads:  state["search_query"]
    Writes: state["runbook_context"], state["runbook_source"]

    Args:
        state: Current AgentState with search_query populated

    Returns:
        Updated AgentState with runbook_context and runbook_source filled in.
    """
    search_query = state["search_query"]
    logger.info(f"[Node 2] Retrieving runbook for query: '{search_query[:60]}...'")

    # Call RAG retriever — returns top-3 chunks ranked by similarity
    results = retrieve(search_query, top_k=3)

    if not results:
        logger.warning("[Node 2] No runbook chunks retrieved — using fallback context")
        return {
            **state,
            "runbook_context": "No runbook found. Use general SRE troubleshooting principles.",
            "runbook_source":  "none",
        }

    # Check similarity quality of top result
    top_similarity = results[0]["similarity"]
    if top_similarity < MIN_SIMILARITY_THRESHOLD:
        logger.warning(
            f"[Node 2] Low similarity score ({top_similarity:.2f}) — "
            f"retrieval may not be accurate"
        )

    # Build combined context string from top-3 chunks
    # This is what gets injected into the LLM prompt
    context_parts = []
    for chunk in results:
        context_parts.append(
            f"--- Runbook: {chunk['source']} (similarity: {chunk['similarity']}) ---\n"
            f"{chunk['content']}"
        )
    runbook_context = "\n\n".join(context_parts)

    # Primary source = the runbook file with highest similarity
    runbook_source = results[0]["source"]

    logger.info(
        f"[Node 2] Retrieved {len(results)} chunks. "
        f"Top match: {runbook_source} (similarity: {top_similarity:.4f})"
    )

    return {
        **state,
        "runbook_context": runbook_context,
        "runbook_source":  runbook_source,
    }