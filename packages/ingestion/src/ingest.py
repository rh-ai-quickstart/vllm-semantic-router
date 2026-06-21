"""Upload sample documents to MinIO and register a vector store in Llamastack."""

import os
import sys
from pathlib import Path

import boto3
from llama_stack_client import LlamaStackClient

MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "http://localhost:9000")
MINIO_ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY", "minioadmin")
MINIO_SECRET_KEY = os.getenv("MINIO_SECRET_KEY", "minioadmin")
MINIO_BUCKET = os.getenv("MINIO_BUCKET", "rag-documents")
LLAMA_STACK_URL = os.getenv("LLAMA_STACK_URL", "http://localhost:8321")
VECTOR_STORE_NAME = os.getenv("VECTOR_STORE_NAME", "sr-demo-docs")
EMBEDDING_MODEL = "all-MiniLM-L6-v2"

SAMPLE_DOCS_DIR = Path(__file__).resolve().parents[3] / "docs" / "sample-docs"


def upload_to_minio() -> list[str]:
    s3 = boto3.client(
        "s3",
        endpoint_url=MINIO_ENDPOINT,
        aws_access_key_id=MINIO_ACCESS_KEY,
        aws_secret_access_key=MINIO_SECRET_KEY,
    )

    try:
        s3.head_bucket(Bucket=MINIO_BUCKET)
    except s3.exceptions.ClientError as e:
        if e.response["Error"]["Code"] == "404":
            s3.create_bucket(Bucket=MINIO_BUCKET)
            print(f"Created bucket: {MINIO_BUCKET}")
        else:
            raise

    uploaded = []
    for doc_path in sorted(SAMPLE_DOCS_DIR.glob("*.md")):
        key = doc_path.name
        s3.upload_file(str(doc_path), MINIO_BUCKET, key)
        print(f"Uploaded: {key}")
        uploaded.append(key)

    return uploaded


def register_vector_store(doc_keys: list[str]) -> None:
    client = LlamaStackClient(base_url=LLAMA_STACK_URL)

    existing = [vs.name for vs in client.vector_stores.list().data]
    if VECTOR_STORE_NAME in existing:
        print(f"Vector store '{VECTOR_STORE_NAME}' already exists, skipping registration.")
        return

    client.vector_stores.register(
        vector_store_id=VECTOR_STORE_NAME,
        embedding_model=EMBEDDING_MODEL,
        provider_id="pgvector",
    )
    print(f"Registered vector store: {VECTOR_STORE_NAME}")

    documents = []
    for key in doc_keys:
        doc_path = SAMPLE_DOCS_DIR / key
        content = doc_path.read_text()
        documents.append({"document_id": key, "content": content, "metadata": {"source": key}})

    client.tool_runtime.rag_tool.insert(
        documents=documents,
        vector_store_id=VECTOR_STORE_NAME,
        chunk_size_in_tokens=512,
    )
    print(f"Inserted {len(documents)} documents into vector store.")


def main() -> None:
    print("=== Ingesting sample documents ===")
    print(f"MinIO: {MINIO_ENDPOINT}")
    print(f"Llamastack: {LLAMA_STACK_URL}")
    print(f"Docs dir: {SAMPLE_DOCS_DIR}")
    print()

    if not SAMPLE_DOCS_DIR.exists():
        print(f"Error: {SAMPLE_DOCS_DIR} not found", file=sys.stderr)
        sys.exit(1)

    doc_keys = upload_to_minio()
    if not doc_keys:
        print("No documents found to ingest.")
        sys.exit(1)

    register_vector_store(doc_keys)
    print("\nIngestion complete.")


if __name__ == "__main__":
    main()
