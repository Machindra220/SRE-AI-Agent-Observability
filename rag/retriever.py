# =============================================================
# rag/retriever.py
# Searches pgvector for runbook chunks most similar to a query.
# Called by agent/nodes/runbook_retriever.py on every alert.
#
# Flow:
#   query text → embed → cosine similarity search → top-k chunks
# =============================================================

import os
import logging
import psycopg2
from rag.embeddings import embed_text

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# How many top chunks to return
# 3 chunks gives enough context without overwhelming the LLM prompt
TOP_K = 3

# PostgreSQL connection config (same as indexer.py)
DB_CONFIG = {
    "host":     os.getenv("PGHOST", "localhost"),
    "port":     os.getenv("PGPORT", "5432"),
    "dbname":   os.getenv("PGDATABASE", "sre_agent"),
    "user":     os.getenv("PGUSER", "postgres"),
    "password": os.getenv("PGPASSWORD", ""),
}


def get_db_connection():
    """Open a connection to PostgreSQL."""
    return psycopg2.connect(**DB_CONFIG)


def retrieve(query: str, top_k: int = TOP_K) -> list[dict]:
    """
    Find the most relevant runbook chunks for a given alert query.

    How it works:
        1. Embed the query into a 384-dim vector
        2. Use pgvector's <=> operator (cosine distance) to rank all chunks
        3. Return top_k most similar chunks with their source and score

    Args:
        query:  The alert text or parsed alert description
        top_k:  Number of chunks to return (default: 3)

    Returns:
        List of dicts sorted by relevance (most relevant first):
        [
            {
                "source": "api-5xx.md",
                "content": "Step 1: Check logs...",
                "similarity": 0.94
            },
            ...
        ]

    Example:
        results = retrieve("high error rate 500 responses sre-ai-agent")
        → top result is api-5xx.md chunk with similarity 0.94
    """
    logger.info(f"Retrieving runbook chunks for query: '{query[:80]}...'")

    # Step 1: Embed the query using the same model used during indexing
    # IMPORTANT: must use the same model — different models produce
    # incompatible vector spaces
    query_vector = embed_text(query)

    # Step 2: Connect to PostgreSQL and run similarity search
    conn = get_db_connection()
    cursor = conn.cursor()

    # pgvector cosine distance query:
    # <=> operator = cosine distance (0 = identical, 2 = opposite)
    # 1 - (embedding <=> query_vector) = cosine SIMILARITY (higher = more similar)
    # ORDER BY distance ASC = most similar first
    cursor.execute(
        """
        SELECT
            source,
            content,
            1 - (embedding <=> %s::vector) AS similarity
        FROM runbook_chunks
        ORDER BY embedding <=> %s::vector
        LIMIT %s
        """,
        (query_vector, query_vector, top_k)
    )

    rows = cursor.fetchall()
    cursor.close()
    conn.close()

    # Step 3: Format results
    results = []
    for source, content, similarity in rows:
        results.append({
            "source": source,
            "content": content,
            "similarity": round(float(similarity), 4)
        })
        logger.info(f"Retrieved: {source} (similarity: {similarity:.4f})")

    if not results:
        logger.warning("No runbook chunks found — is the vector DB indexed?")

    return results


def retrieve_as_context(query: str, top_k: int = TOP_K) -> str:
    """
    Convenience function that returns retrieved chunks as a
    single formatted string ready to inject into an LLM prompt.

    Args:
        query:  Alert text to search for
        top_k:  Number of chunks to retrieve

    Returns:
        Formatted string combining all retrieved chunks:

        --- Runbook: api-5xx.md (similarity: 0.94) ---
        Step 1: Check 5xx logs...

        --- Runbook: api-5xx.md (similarity: 0.91) ---
        Step 2: Describe pods...
    """
    chunks = retrieve(query, top_k)

    if not chunks:
        return "No relevant runbook found."

    context_parts = []
    for chunk in chunks:
        context_parts.append(
            f"--- Runbook: {chunk['source']} (similarity: {chunk['similarity']}) ---\n"
            f"{chunk['content']}"
        )

    return "\n\n".join(context_parts)