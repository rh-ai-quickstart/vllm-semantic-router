from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class ChatMessage(BaseModel):
    role: Literal["user", "assistant", "system"]
    content: str = Field(..., min_length=1, max_length=32_000)


class ChatRequest(BaseModel):
    messages: list[ChatMessage] = Field(..., min_length=1, max_length=100)


class RoutingMetadata(BaseModel):
    selected_model: str | None = None
    selected_decision: str | None = None
    selected_confidence: float | None = None
    signal_confidences: dict[str, float] | None = None
    matched_signals: dict[str, list[str]] | None = None
    recommended_models: list[str] | None = None
    routing_decision: str | None = None

    @classmethod
    def from_eval_response(cls, data: dict) -> RoutingMetadata:
        decision_result = data.get("decision_result") or {}
        return cls(
            selected_model=(data.get("recommended_models") or [None])[0],
            selected_decision=decision_result.get("decision_name"),
            selected_confidence=decision_result.get("confidence"),
            signal_confidences=data.get("signal_confidences"),
            matched_signals={k: v for k, v in (decision_result.get("matched_signals") or {}).items() if v} or None,
            recommended_models=data.get("recommended_models"),
            routing_decision=data.get("routing_decision"),
        )


class RoutingEvent(BaseModel):
    type: Literal["routing"] = "routing"
    metadata: RoutingMetadata


class DeltaEvent(BaseModel):
    type: Literal["delta"] = "delta"
    content: str


class ErrorEvent(BaseModel):
    type: Literal["error"] = "error"
    message: str


class DoneEvent(BaseModel):
    type: Literal["done"] = "done"
