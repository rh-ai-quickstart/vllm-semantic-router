from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest

from src.schemas.chat import RoutingMetadata
from src.services.router_client import RouterClient, is_done_line, parse_sse_content


class TestParseSSEContent:
    def test_valid_delta(self):
        line = 'data: {"choices":[{"delta":{"content":"Hello"},"index":0}]}'
        assert parse_sse_content(line) == "Hello"

    def test_done_line(self):
        assert parse_sse_content("data: [DONE]") is None

    def test_done_line_with_whitespace(self):
        assert parse_sse_content("data:  [DONE] ") is None

    def test_non_data_line(self):
        assert parse_sse_content("event: message") is None
        assert parse_sse_content("") is None
        assert parse_sse_content(": comment") is None

    def test_malformed_json(self):
        assert parse_sse_content("data: {broken") is None

    def test_empty_choices(self):
        assert parse_sse_content('data: {"choices":[]}') is None

    def test_missing_delta(self):
        assert parse_sse_content('data: {"choices":[{"index":0}]}') is None

    def test_missing_content_in_delta(self):
        assert parse_sse_content('data: {"choices":[{"delta":{},"index":0}]}') is None

    def test_no_choices_key(self):
        assert parse_sse_content('data: {"id":"abc"}') is None


class TestIsDoneLine:
    def test_exact(self):
        assert is_done_line("data: [DONE]") is True

    def test_with_whitespace(self):
        assert is_done_line("  data: [DONE]  ") is True

    def test_not_done(self):
        assert is_done_line("data: {\"choices\":[]}") is False

    def test_empty(self):
        assert is_done_line("") is False


class TestRoutingMetadataFromEvalResponse:
    def test_full_response(self):
        data = {
            "recommended_models": ["research-agent"],
            "decision_result": {
                "decision_name": "research",
                "confidence": 0.95,
                "matched_signals": {"domains": ["computer science"]},
            },
            "signal_confidences": {"domain:computer science": 0.95},
            "routing_decision": "research",
        }
        meta = RoutingMetadata.from_eval_response(data)
        assert meta.selected_model == "research-agent"
        assert meta.selected_decision == "research"
        assert meta.selected_confidence == 0.95
        assert meta.matched_signals == {"domains": ["computer science"]}
        assert meta.recommended_models == ["research-agent"]
        assert meta.routing_decision == "research"

    def test_missing_decision_result(self):
        data = {"recommended_models": ["general-agent"]}
        meta = RoutingMetadata.from_eval_response(data)
        assert meta.selected_model == "general-agent"
        assert meta.selected_decision is None
        assert meta.selected_confidence is None

    def test_empty_recommended_models(self):
        data = {"recommended_models": [], "decision_result": {}}
        meta = RoutingMetadata.from_eval_response(data)
        assert meta.selected_model is None

    def test_null_matched_signals(self):
        data = {
            "decision_result": {"matched_signals": None},
        }
        meta = RoutingMetadata.from_eval_response(data)
        assert meta.matched_signals is None

    def test_empty_matched_signals_filtered(self):
        data = {
            "decision_result": {
                "matched_signals": {"domains": ["research"], "keywords": []},
            },
        }
        meta = RoutingMetadata.from_eval_response(data)
        assert meta.matched_signals == {"domains": ["research"]}

    def test_completely_empty(self):
        meta = RoutingMetadata.from_eval_response({})
        assert meta.selected_model is None
        assert meta.selected_decision is None


class TestRouterClientEval:
    @pytest.mark.asyncio
    async def test_eval_success(self):
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "recommended_models": ["general-agent"],
            "decision_result": {"decision_name": "general", "confidence": 0.8},
            "signal_confidences": {"domain:other": 0.8},
            "routing_decision": "general",
        }
        mock_response.raise_for_status = MagicMock()

        client = RouterClient("http://envoy:8801", "http://router:8080")
        client._client = AsyncMock()
        client._client.post.return_value = mock_response

        result = await client.eval("hello")

        client._client.post.assert_called_once_with(
            "http://router:8080/api/v1/eval",
            json={"text": "hello", "options": {"return_probabilities": True}},
        )
        assert result.selected_decision == "general"

    @pytest.mark.asyncio
    async def test_eval_raises_on_error(self):
        mock_response = MagicMock()
        mock_response.raise_for_status.side_effect = httpx.HTTPStatusError(
            "500", request=MagicMock(), response=MagicMock()
        )

        client = RouterClient("http://envoy:8801", "http://router:8080")
        client._client = AsyncMock()
        client._client.post.return_value = mock_response

        with pytest.raises(httpx.HTTPStatusError):
            await client.eval("test")


class TestRouterClientHealth:
    @pytest.mark.asyncio
    async def test_health_success(self):
        mock_response = MagicMock()
        mock_response.json.return_value = {"status": "ok"}

        client = RouterClient("http://envoy:8801", "http://router:8080")
        client._client = AsyncMock()
        client._client.get.return_value = mock_response

        result = await client.health()
        assert result == {"semantic_router": {"status": "ok"}}

    @pytest.mark.asyncio
    async def test_health_error(self):
        client = RouterClient("http://envoy:8801", "http://router:8080")
        client._client = AsyncMock()
        client._client.get.side_effect = httpx.ConnectError("connection refused")

        result = await client.health()
        assert result["semantic_router"]["status"] == "error"
        assert "connection refused" in result["semantic_router"]["detail"]


class TestRouterClientClose:
    @pytest.mark.asyncio
    async def test_close(self):
        client = RouterClient("http://envoy:8801", "http://router:8080")
        client._client = AsyncMock()

        await client.close()
        client._client.aclose.assert_called_once()
