# =============================================================
# rag/embeddings.py
# Local embeddings using fastembed library.
#
# Why fastembed instead of Gemini embeddings?
# - Runs locally — no API calls, no internet needed
# - No torch/CUDA required — uses onnxruntime (CPU only)
# - Model size: ~130MB (vs 2GB for sentence-transformers+torch)
# - Dimensions: 384 (small, fast, good quality for retrieval)
# - Gemini API is used ONLY for LLM reasoning (diagnoser.py)
#
# Model: BAAI/bge-small-en-v1.5
# - Downloaded once, cached locally in ~/.cache/fastembed/
# - Output: 384-dimensional vector per text input
# =============================================================

import logging
from fastembed import TextEmbedding

logger = logging.getLogger(__name__)

MODEL_NAME = "BAAI/bge-small-en-v1.5"
EMBEDDING_DIM = 384

_model: TextEmbedding | None = None


def get_model() -> TextEmbedding:
    global _model
    if _model is None:
        logger.info(f"Loading embedding model: {MODEL_NAME}")
        _model = TextEmbedding(MODEL_NAME)
        logger.info("Embedding model loaded successfully")
    return _model


def embed_text(text: str) -> list[float]:
    model = get_model()
    embeddings = list(model.embed([text]))
    return embeddings[0].tolist()


def embed_query(text: str) -> list[float]:
    return embed_text(text)


def embed_batch(texts: list[str]) -> list[list[float]]:
    model = get_model()
    logger.info(f"Embedding {len(texts)} chunks...")
    embeddings = list(model.embed(texts))
    return [e.tolist() for e in embeddings]
