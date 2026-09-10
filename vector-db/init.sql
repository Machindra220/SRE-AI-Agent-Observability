-- =============================================================
-- vector-db/init.sql
-- Sets up pgvector extension and runbook_chunks table.
-- Run once before indexing runbooks.
-- =============================================================

-- Step 1: Enable pgvector extension
-- This adds vector data type and similarity search to PostgreSQL.
CREATE EXTENSION IF NOT EXISTS vector;

-- Step 2: Create table to store runbook chunks + their embeddings
-- Each row = one chunk of a runbook file
CREATE TABLE IF NOT EXISTS runbook_chunks (
    id          SERIAL PRIMARY KEY,           -- auto-increment row ID
    source      TEXT NOT NULL,                -- e.g. "api-5xx.md"
    content     TEXT NOT NULL,                -- the actual runbook text chunk
    embedding   vector(384),                  -- 384-dim vector from all-MiniLM-L6-v2
    created_at  TIMESTAMP DEFAULT NOW()       -- when this chunk was indexed
);

-- Step 3: Create index for fast similarity search
-- ivfflat = Inverted File Flat index (best for < 1 million vectors)
-- vector_cosine_ops = use cosine similarity (standard for text embeddings)
-- lists = 10 means vectors are grouped into 10 clusters for faster search
CREATE INDEX IF NOT EXISTS runbook_chunks_embedding_idx
    ON runbook_chunks
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 10);

-- Step 4: Utility — clear all chunks (use when re-indexing runbooks)
-- Usage: psql -c "TRUNCATE TABLE runbook_chunks RESTART IDENTITY;"
-- (not run automatically — just documented here for reference)