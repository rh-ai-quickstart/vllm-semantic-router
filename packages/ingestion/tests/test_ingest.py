from unittest.mock import MagicMock, patch

import pytest
from botocore.exceptions import ClientError

from src.ingest import upload_to_minio, register_vector_store, main


@pytest.fixture
def mock_s3():
    with patch("src.ingest.boto3") as mock_boto3:
        client = MagicMock()
        client.exceptions.ClientError = ClientError
        mock_boto3.client.return_value = client
        yield client


@pytest.fixture
def mock_llamastack():
    with patch("src.ingest.LlamaStackClient") as mock_cls:
        client = MagicMock()
        mock_cls.return_value = client
        yield client


class TestUploadToMinio:
    def test_creates_bucket_if_not_exists(self, mock_s3, tmp_path):
        mock_s3.head_bucket.side_effect = ClientError(
            {"Error": {"Code": "404", "Message": "Not Found"}}, "HeadBucket"
        )
        with patch("src.ingest.SAMPLE_DOCS_DIR", tmp_path):
            upload_to_minio()
        mock_s3.create_bucket.assert_called_once()

    def test_skips_bucket_creation_if_exists(self, mock_s3, tmp_path):
        with patch("src.ingest.SAMPLE_DOCS_DIR", tmp_path):
            upload_to_minio()
        mock_s3.create_bucket.assert_not_called()

    def test_uploads_md_files(self, mock_s3, tmp_path):
        (tmp_path / "doc1.md").write_text("content1")
        (tmp_path / "doc2.md").write_text("content2")
        (tmp_path / "readme.txt").write_text("ignored")

        with patch("src.ingest.SAMPLE_DOCS_DIR", tmp_path):
            keys = upload_to_minio()

        assert keys == ["doc1.md", "doc2.md"]
        assert mock_s3.upload_file.call_count == 2

    def test_returns_empty_list_when_no_docs(self, mock_s3, tmp_path):
        with patch("src.ingest.SAMPLE_DOCS_DIR", tmp_path):
            keys = upload_to_minio()
        assert keys == []


class TestRegisterVectorStore:
    def test_registers_new_store(self, mock_llamastack, tmp_path):
        mock_llamastack.vector_stores.list.return_value = MagicMock(data=[])

        (tmp_path / "doc.md").write_text("test content")
        with patch("src.ingest.SAMPLE_DOCS_DIR", tmp_path):
            register_vector_store(["doc.md"])

        mock_llamastack.vector_stores.register.assert_called_once()
        mock_llamastack.tool_runtime.rag_tool.insert.assert_called_once()

    def test_skips_if_store_exists(self, mock_llamastack):
        existing = MagicMock()
        existing.name = "sr-demo-docs"
        mock_llamastack.vector_stores.list.return_value = MagicMock(data=[existing])

        register_vector_store(["doc.md"])

        mock_llamastack.vector_stores.register.assert_not_called()
        mock_llamastack.tool_runtime.rag_tool.insert.assert_not_called()

    def test_inserts_documents_with_content(self, mock_llamastack, tmp_path):
        mock_llamastack.vector_stores.list.return_value = MagicMock(data=[])

        (tmp_path / "a.md").write_text("alpha")
        (tmp_path / "b.md").write_text("beta")

        with patch("src.ingest.SAMPLE_DOCS_DIR", tmp_path):
            register_vector_store(["a.md", "b.md"])

        call_args = mock_llamastack.tool_runtime.rag_tool.insert.call_args
        docs = call_args.kwargs["documents"]
        assert len(docs) == 2
        assert docs[0]["content"] == "alpha"
        assert docs[1]["document_id"] == "b.md"


class TestMain:
    def test_exits_if_docs_dir_missing(self, tmp_path):
        missing = tmp_path / "nonexistent"
        with patch("src.ingest.SAMPLE_DOCS_DIR", missing):
            with pytest.raises(SystemExit, match="1"):
                main()

    def test_exits_if_no_documents(self, mock_s3, tmp_path):
        with patch("src.ingest.SAMPLE_DOCS_DIR", tmp_path):
            with pytest.raises(SystemExit, match="1"):
                main()
