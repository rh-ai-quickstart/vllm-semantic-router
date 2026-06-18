from __future__ import annotations

import logging
from collections.abc import AsyncGenerator

from src.schemas.chat import ChatMessage, DeltaEvent, DoneEvent, ErrorEvent, RoutingEvent, RoutingMetadata
from src.services.router_client import RouterClient, is_done_line, parse_sse_content

logger = logging.getLogger(__name__)

BLOCKED_DECISIONS = {"blocked"}
WARNING_DECISIONS = {"pii-flagged"}


def _sse(event: RoutingEvent | DeltaEvent | ErrorEvent | DoneEvent) -> str:
    return f"data: {event.model_dump_json()}\n\n"


class ChatService:
    def __init__(self, router_client: RouterClient) -> None:
        self._router = router_client

    async def stream_response(self, messages: list[ChatMessage]) -> AsyncGenerator[str, None]:
        last_user_msg = next(
            (m.content for m in reversed(messages) if m.role == "user"), ""
        )
        routing = await self._safe_eval(last_user_msg)
        yield _sse(RoutingEvent(metadata=routing))

        if routing.selected_decision in BLOCKED_DECISIONS:
            yield _sse(ErrorEvent(message="Request blocked by jailbreak guardrail."))
            yield _sse(DoneEvent())
            return

        try:
            async with self._router.stream_chat(messages) as response:
                async for line in response.aiter_lines():
                    if is_done_line(line):
                        break
                    content = parse_sse_content(line)
                    if content:
                        yield _sse(DeltaEvent(content=content))

                yield _sse(DoneEvent())

        except Exception as exc:
            logger.exception("Chat stream error")
            yield _sse(ErrorEvent(message="An internal error occurred. Please try again."))
            yield _sse(DoneEvent())

    async def _safe_eval(self, text: str) -> RoutingMetadata:
        try:
            return await self._router.eval(text)
        except Exception:
            logger.warning("Eval API call failed, returning empty metadata", exc_info=True)
            return RoutingMetadata()
