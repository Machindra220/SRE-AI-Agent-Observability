# =============================================================
# rag/embeddings.py
# Embedding wrapper using Google Gemini API.
#
# Why Gemini embeddings instead of local model?
# - Zero local RAM usage (no model loaded into memory)
# - No torch, no CUDA, no onnxruntime
# - Embeddings happen via API call (free tier)
# - Model: gemini-embedding-001 (3072-dim, high quality)
# - Works on any machine regardless of RAM/CPU
# =============================================================

import os
import logging
import google.generativeai as genai

logger = logging.getLogger(__name__)

# Configure Gemini client
genai.configure(api_key=os.environ["GEMINI_API_KEY"])

# Gemini embedding model
# gemini-embedding-001 — Google's latest embedding model
# Output: 3072-dimensional vector
EMBEDDING_MODEL = "models/gemini-embedding-001"

# NOTE: We changed from 384-dim (fastembed) to 3072-dim (Gemini)
# Vector dimension: 768 (Gemini gemini-embedding-001 with output_dimensionality=768)
EMBEDDING_DIM = 768


def embed_text(text: str) -> list[float]:
    """
    Convert a single string into a 3072-dimensional embedding vector
    using Gemini gemini-embedding-001 API.

    Args:
        text: Input text to embed (alert, runbook chunk, query)

    Returns:
        List of 3072 floats representing the semantic meaning of the text.

    Example:
        embed_text("pod is crashing") → [0.23, -0.87, 0.45, ...]
    """
    result = genai.embed_content(
        model=EMBEDDING_MODEL,
        content=text,
        task_type="retrieval_document",
        output_dimensionality=768  # optimised for search/retrieval
    )
    return result["embedding"]


def embed_query(text: str) -> list[float]:
    """
    Embed a search query (alert text).
    Uses task_type="retrieval_query",
        output_dimensionality=768 — optimised for query side of search.

    Args:
        text: Alert text or search query

    Returns:
        List of 3072 floats
    """
    result = genai.embed_content(
        model=EMBEDDING_MODEL,
        content=text,
        task_type="retrieval_query",
        output_dimensionality=768  # optimised for query side
    )
    return result["embedding"]


def embed_batch(texts: list[str]) -> list[list[float]]:
    """
    Embed a list of texts one by one.
    Gemini API doesn't support batch embedding — we loop.

    Args:
        texts: List of strings to embed

    Returns:
        List of 3072-dim vectors, one per input text.
    """
    embeddings = []
    for i, text in enumerate(texts):
        logger.info(f"Embedding chunk {i+1}/{len(texts)}")
        embedding = embed_text(text)
        embeddings.append(embedding)
    return embeddings