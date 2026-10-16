"""Chunks documents in DOCS_DIR, embeds them with Gemini and stores them in ChromaDB."""
import hashlib
import os
import pathlib

import chromadb
from google import genai

DOCS_DIR = pathlib.Path(os.getenv("DOCS_DIR", "/app/docs"))
CHROMA_HOST = os.getenv("CHROMA_HOST", "localhost")
CHROMA_PORT = int(os.getenv("CHROMA_PORT", "8000"))
COLLECTION = os.getenv("CHROMA_COLLECTION", "workshop_docs")
EMBED_MODEL = os.getenv("EMBED_MODEL", "gemini-embedding-001")
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "800"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "120"))
BATCH = 50


def chunk(text: str):
    """Fixed-size character chunks with overlap, breaking on paragraph boundaries where possible."""
    text = text.strip()
    start = 0
    while start < len(text):
        end = min(start + CHUNK_SIZE, len(text))
        if end < len(text):
            cut = text.rfind("\n\n", start, end)
            if cut > start + CHUNK_SIZE // 2:
                end = cut
        yield text[start:end].strip()
        if end >= len(text):
            break
        start = max(end - CHUNK_OVERLAP, start + 1)


def main():
    client = genai.Client()
    collection = chromadb.HttpClient(host=CHROMA_HOST, port=CHROMA_PORT).get_or_create_collection(COLLECTION)

    ids, docs, metas = [], [], []
    for path in sorted(DOCS_DIR.glob("**/*")):
        if path.suffix.lower() not in {".md", ".txt"}:
            continue
        for i, piece in enumerate(chunk(path.read_text(encoding="utf-8"))):
            if piece:
                ids.append(hashlib.sha1(f"{path.name}-{i}".encode()).hexdigest())
                docs.append(piece)
                metas.append({"source": path.name, "chunk": i})

    for b in range(0, len(docs), BATCH):
        batch = docs[b:b + BATCH]
        result = client.models.embed_content(model=EMBED_MODEL, contents=batch)
        collection.upsert(
            ids=ids[b:b + BATCH],
            documents=batch,
            metadatas=metas[b:b + BATCH],
            embeddings=[e.values for e in result.embeddings],
        )
    print(f"Ingested {len(docs)} chunks from {DOCS_DIR} into collection '{COLLECTION}'.")


if __name__ == "__main__":
    main()
