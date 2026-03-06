from .raganything import RAGAnything as RAGAnything
from .config import RAGAnythingConfig as RAGAnythingConfig

__version__ = "1.2.9"
__author__ = "Zirui Guo"
__url__ = "https://github.com/HKUDS/RAG-Anything"

__all__ = ["RAGAnything", "RAGAnythingConfig"]


def get_version() -> str:
    """Return the RAG-Anything version string."""
    return __version__
