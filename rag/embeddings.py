# =============================================================
# rag/embeddings.py
# Wrapper around the sentence-transformer embedding model.
# Single place to load the model and generate embeddings.
# All other files import from here — change model in one place.
# =============================================================

from sentence_transformers import SentenceTransformer
import logging

logger = logging.getLogger(__name__)

# Model: all-MiniLM-L6-v2
# - Free, runs on CPU (no GPU needed)
# - Output: 384-dimensional vector per text input
# - Good balance of speed and quality for semantic search
MODEL_NAME = "all-MiniLM-L6-v2"

# Load model once at module import time (not on every call)
# This avoids reloading the model on every embed request
_model: SentenceTransformer | None = None


def get_model() -> SentenceTransformer:
    """
    Returns the embedding model, loading it on first call.
    Subsequent calls return the already-loaded model (singleton pattern).
    """
    global _model
    if _model is None:
        logger.info(f"Loading embedding model: {MODEL_NAME}")
        _model = SentenceTransformer(MODEL_NAME)
        logger.info("Embedding model loaded successfully")
    return _model


def embed_text(text: str) -> list[float]:
    """
    Convert a single string into a 384-dimensional embedding vector.

    Args:
        text: The input text to embed (alert, runbook chunk, query, etc.)

    Returns:
        List of 384 floats representing the semantic meaning of the text.

    Example:
        embed_text("pod is crashing") → [0.23, -0.87, 0.45, ...]
    """
    model = get_model()
    # encode() returns a numpy array — convert to plain Python list
    # so it can be serialised to JSON or stored in pgvector
    vector = model.encode(text, convert_to_numpy=True)
    return vector.tolist()


def embed_batch(texts: list[str]) -> list[list[float]]:
    """
    Convert a list of strings into embeddings in one batch call.
    More efficient than calling embed_text() in a loop.

    Args:
        texts: List of strings to embed

    Returns:
        List of 384-dim vectors, one per input text.

    Example:
        Used by indexer.py to embed all runbook chunks at once.
    """
    model = get_model()
    vectors = model.encode(texts, convert_to_numpy=True, show_progress_bar=True)
    return vectors.tolist()