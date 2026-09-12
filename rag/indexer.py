# =============================================================
# rag/indexer.py
# One-time (or periodic) job that:
#   1. Reads all runbook .md files from docs/runbooks/
#   2. Splits them into chunks
#   3. Embeds each chunk using embeddings.py
#   4. Stores chunks + vectors in pgvector (runbook_chunks table)
#
# Run this before starting the agent:
#   python -m rag.indexer
# =============================================================

import os
import re
import logging
import psycopg2
from pathlib import Path
from rag.embeddings import embed_batch

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────
# Path to runbooks folder (relative to repo root)
RUNBOOKS_DIR = Path("docs/runbooks")

# Chunk size: how many characters per chunk
# 500 chars ≈ 3-5 sentences — small enough for precise retrieval
CHUNK_SIZE = 500

# Chunk overlap: how many chars to repeat between chunks
# Overlap prevents cutting a sentence in half at chunk boundaries
CHUNK_OVERLAP = 50

# PostgreSQL connection — reads from environment variables
# Set these in your shell or .env file before running
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


def read_runbooks() -> list[dict]:
    """
    Read all .md files from docs/runbooks/.

    Returns:
        List of dicts: [{ "source": "api-5xx.md", "content": "..." }, ...]
    """
    runbooks = []
    for filepath in sorted(RUNBOOKS_DIR.glob("*.md")):
        content = filepath.read_text(encoding="utf-8")
        runbooks.append({
            "source": filepath.name,   # e.g. "api-5xx.md"
            "content": content
        })
        logger.info(f"Read runbook: {filepath.name} ({len(content)} chars)")
    return runbooks


def chunk_text(text: str) -> list[str]:
    """
    Split text into overlapping chunks of CHUNK_SIZE characters.

    Why overlap? If a sentence spans a chunk boundary, we'd lose context.
    Overlap ensures each chunk has some shared text with its neighbours.

    Example (CHUNK_SIZE=20, CHUNK_OVERLAP=5):
        "Hello world this is a test of chunking"
        → ["Hello world this is ", "is a test of chunk", "chunking"]
    """
    chunks = []
    start = 0
    text = text.strip()

    while start < len(text):
        end = start + CHUNK_SIZE
        chunk = text[start:end]

        # Try to end chunk at a sentence boundary (. or \n)
        # so we don't cut mid-sentence
        if end < len(text):
            last_period = chunk.rfind(". ")
            last_newline = chunk.rfind("\n")
            boundary = max(last_period, last_newline)
            if boundary > CHUNK_SIZE // 2:   # only use boundary if it's not too early
                chunk = text[start:start + boundary + 1]

        chunks.append(chunk.strip())
        advance = len(chunk) - CHUNK_OVERLAP
        if advance <= 0:          # prevent infinite loop
            advance = CHUNK_SIZE  # force forward progress
        start += advance

    return [c for c in chunks if len(c) > 20]  # skip tiny leftover chunks


def clear_existing_chunks(cursor, source: str):
    """
    Delete existing chunks for a runbook before re-indexing.
    This prevents duplicate entries if indexer is run multiple times.
    """
    cursor.execute(
        "DELETE FROM runbook_chunks WHERE source = %s",
        (source,)
    )


def insert_chunks(cursor, source: str, chunks: list[str], embeddings: list[list[float]]):
    """
    Insert all chunks and their embeddings into the runbook_chunks table.
    """
    for chunk, embedding in zip(chunks, embeddings):
        cursor.execute(
            """
            INSERT INTO runbook_chunks (source, content, embedding)
            VALUES (%s, %s, %s)
            """,
            (source, chunk, embedding)
        )


def index_runbooks():
    """
    Main indexing function — orchestrates the full pipeline:
    read → chunk → embed → store
    """
    logger.info("Starting runbook indexing pipeline")

    # Step 1: Read all runbook files
    runbooks = read_runbooks()
    if not runbooks:
        logger.warning(f"No .md files found in {RUNBOOKS_DIR}")
        return

    # Step 2: Connect to PostgreSQL
    conn = get_db_connection()
    cursor = conn.cursor()

    total_chunks = 0

    for runbook in runbooks:
        source = runbook["source"]
        content = runbook["content"]

        # Step 3: Chunk the runbook text
        chunks = chunk_text(content)
        logger.info(f"{source}: {len(chunks)} chunks created")

        # Step 4: Embed all chunks in one batch call (efficient)
        embeddings = embed_batch(chunks)

        # Step 5: Clear old chunks for this runbook (idempotent re-indexing)
        clear_existing_chunks(cursor, source)

        # Step 6: Insert new chunks + embeddings into pgvector
        insert_chunks(cursor, source, chunks, embeddings)
        total_chunks += len(chunks)

        logger.info(f"{source}: indexed {len(chunks)} chunks into pgvector")

    # Commit all inserts in one transaction
    conn.commit()
    cursor.close()
    conn.close()

    logger.info(f"Indexing complete — {total_chunks} total chunks stored")


if __name__ == "__main__":
    index_runbooks()