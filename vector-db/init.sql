-- =============================================================
-- vector-db/init.sql
-- Sets up pgvector extension and runbook_chunks table.
-- Run once before indexing runbooks.
--
-- NOTE: Using 768-dim vectors (Gemini text-embedding-004)
-- =============================================================

-- Step 1: Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Step 2: Drop existing table if schema changed (768 vs 384 dim)
DROP TABLE IF EXISTS runbook_chunks;

-- Step 3: Create table with 768-dim vector (Gemini embedding size)
CREATE TABLE IF NOT EXISTS runbook_chunks (
    id          SERIAL PRIMARY KEY,
    source      TEXT NOT NULL,        -- e.g. "api-5xx.md"
    content     TEXT NOT NULL,        -- the actual runbook text chunk
    embedding   vector(384),          -- 768-dim vector from Gemini text-embedding-004
    created_at  TIMESTAMP DEFAULT NOW()
);

-- Step 4: Create index for fast similarity search
CREATE INDEX IF NOT EXISTS runbook_chunks_embedding_idx
    ON runbook_chunks
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 10);