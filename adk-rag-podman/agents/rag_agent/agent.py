"""ADK agent that answers questions using a RAG tool backed by ChromaDB."""
import os

import chromadb
from google import genai
from google.adk.agents import Agent

CHROMA_HOST = os.getenv("CHROMA_HOST", "localhost")
CHROMA_PORT = int(os.getenv("CHROMA_PORT", "8000"))
COLLECTION = os.getenv("CHROMA_COLLECTION", "workshop_docs")
EMBED_MODEL = os.getenv("EMBED_MODEL", "gemini-embedding-001")
CHAT_MODEL = os.getenv("CHAT_MODEL", "gemini-2.5-flash")
TOP_K = int(os.getenv("TOP_K", "4"))

_genai_client = None
_collection = None


def _clients():
    """Create clients lazily so the container starts even if Chroma is still booting."""
    global _genai_client, _collection
    if _genai_client is None:
        _genai_client = genai.Client()  # reads GOOGLE_API_KEY from the environment
    if _collection is None:
        chroma = chromadb.HttpClient(host=CHROMA_HOST, port=CHROMA_PORT)
        _collection = chroma.get_or_create_collection(COLLECTION)
    return _genai_client, _collection


def search_knowledge_base(query: str) -> dict:
    """Searches the company knowledge base for passages relevant to the question.

    Args:
        query: The user's question or the key terms to look up.

    Returns:
        A dict with 'status' and a list of 'results', each holding the passage
        text and its source document name.
    """
    try:
        client, collection = _clients()
        emb = client.models.embed_content(model=EMBED_MODEL, contents=query)
        hits = collection.query(query_embeddings=[emb.embeddings[0].values], n_results=TOP_K)
        results = [
            {"text": doc, "source": (meta or {}).get("source", "unknown")}
            for doc, meta in zip(hits["documents"][0], hits["metadatas"][0])
        ]
        if not results:
            return {"status": "no_results", "results": []}
        return {"status": "success", "results": results}
    except Exception as exc:  # surface errors to the model instead of crashing the run
        return {"status": "error", "error_message": str(exc)}


root_agent = Agent(
    name="rag_agent",
    model=CHAT_MODEL,
    description="Answers questions using the company knowledge base.",
    instruction=(
        "You are a helpful assistant for company employees. "
        "For every factual question, first call search_knowledge_base. "
        "Answer only from the returned passages and cite the source document names. "
        "If the passages do not contain the answer, say you don't know instead of guessing. "
        "If the tool returns an error, tell the user the knowledge base is unavailable."
    ),
    tools=[search_knowledge_base],
)
