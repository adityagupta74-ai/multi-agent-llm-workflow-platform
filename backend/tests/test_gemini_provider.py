"""Tests for Google Gemini / Vertex AI provider wiring (no network calls)."""

from types import SimpleNamespace

import pytest

from backend.app.core.config import Settings
from backend.app.documents.embeddings import provider as emb
from backend.app.services.llm import get_llm


def test_get_llm_gemini_api_key():
    cfg = Settings(LLM_PROVIDER="gemini", LLM_MODEL="gemini-2.5-flash", LLM_API_KEY="test-key")
    llm = get_llm(settings=cfg)
    assert type(llm).__name__ == "ChatGoogleGenerativeAI"
    assert "gemini-2.5-flash" in llm.model


def test_get_llm_gemini_requires_key():
    cfg = Settings(LLM_PROVIDER="gemini", LLM_API_KEY=None)
    with pytest.raises(ValueError, match="LLM_API_KEY"):
        get_llm(settings=cfg)


def test_get_llm_vertex_requires_project():
    cfg = Settings(LLM_PROVIDER="vertex", GOOGLE_CLOUD_PROJECT=None)
    with pytest.raises(ValueError, match="GOOGLE_CLOUD_PROJECT"):
        get_llm(settings=cfg)


def test_gemini_embeddings_batching_and_task_types(monkeypatch):
    calls = []

    class FakeModels:
        def embed_content(self, model, contents, config):
            calls.append((model, list(contents), config.task_type, config.output_dimensionality))
            return SimpleNamespace(embeddings=[SimpleNamespace(values=[0.1] * 8) for _ in contents])

    p = emb.GeminiEmbeddingProvider(model="gemini-embedding-001", dimension=8, api_key="k", batch_size=2)
    p._client = SimpleNamespace(models=FakeModels())

    docs = p.embed_documents(["a", "b", "c"])
    assert len(docs) == 3 and all(len(v) == 8 for v in docs)
    assert [c[1] for c in calls] == [["a", "b"], ["c"]]
    assert all(c[2] == "RETRIEVAL_DOCUMENT" and c[3] == 8 for c in calls)

    q = p.embed_query("question")
    assert len(q) == 8
    assert calls[-1][2] == "RETRIEVAL_QUERY"
    assert p.embed_documents([]) == []
