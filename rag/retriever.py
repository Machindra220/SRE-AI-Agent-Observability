# =============================================================
# rag/retriever.py
# Searches pgvector for runbook chunks most similar to a query.
# Uses Gemini embed_query for the query side of search.
# =============================================================

import os
import logging
import psycopg2
from rag.embeddings import embed_query  # query-optimised embedding

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

TOP_K = 3

DB_CONFIG = {
    "host":     os.getenv("PGHOST", "localhost"),
    "port":     os.getenv("PGPORT", "5432"),
    "dbname":   os.getenv("PGDATABASE", "sre_agent"),
    "user":     os.getenv("PGUSER", "sre_user"),
    "password": os.getenv("PGPASSWORD", "sre_pass"),
}


def get_db_connection():
    return psycopg2.connect(**DB_CONFIG)


def retrieve(query: str, top_k: int = TOP_K) -> list[dict]:
    """
    Find the most relevant runbook chunks for a given alert query.

    Args:
        query:  Alert text or parsed alert description
        top_k:  Number of chunks to return (default: 3)

    Returns:
        List of dicts sorted by relevance:
        [{ "source": "api-5xx.md", "content": "...", "similarity": 0.94 }]
    """
    logger.info(f"Retrieving runbook chunks for: '{query[:80]}...'")

    # Use query-optimised embedding (retrieval_query task type)
    query_vector = embed_query(query)

    conn   = get_db_connection()
    cursor = conn.cursor()

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

    results = []
    for source, content, similarity in rows:
        results.append({
            "source":     source,
            "content":    content,
            "similarity": round(float(similarity), 4)
        })
        logger.info(f"Retrieved: {source} (similarity: {similarity:.4f})")

    if not results:
        logger.warning("No chunks found — is the vector DB indexed?")

    return results


def retrieve_as_context(query: str, top_k: int = TOP_K) -> str:
    """
    Returns retrieved chunks as a formatted string for LLM prompt injection.
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