import { renderHook, act } from "@testing-library/react";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { useChat } from "../src/hooks/useChat";
import type { StreamEvent } from "../src/types/chat";

let mockEvents: StreamEvent[] = [];

vi.mock("../src/services/api", () => ({
  streamChat: vi.fn(async function* () {
    for (const event of mockEvents) {
      yield event;
    }
  }),
}));

beforeEach(() => {
  mockEvents = [];
  vi.clearAllMocks();
});

describe("useChat", () => {
  it("adds user and assistant messages on sendMessage", async () => {
    mockEvents = [{ type: "done" }];

    const { result } = renderHook(() => useChat());

    await act(async () => {
      await result.current.sendMessage("hello");
    });

    expect(result.current.messages).toHaveLength(2);
    expect(result.current.messages[0].role).toBe("user");
    expect(result.current.messages[0].content).toBe("hello");
    expect(result.current.messages[1].role).toBe("assistant");
  });

  it("accumulates delta content", async () => {
    mockEvents = [
      { type: "delta", content: "Hello" },
      { type: "delta", content: " world" },
      { type: "done" },
    ];

    const { result } = renderHook(() => useChat());

    await act(async () => {
      await result.current.sendMessage("hi");
    });

    const assistant = result.current.messages[1];
    expect(assistant.content).toBe("Hello world");
  });

  it("attaches routing metadata to assistant message", async () => {
    const metadata = {
      selected_model: "research-agent",
      selected_decision: "research",
      selected_confidence: 0.95,
      signal_confidences: null,
      matched_signals: null,
      recommended_models: null,
      routing_decision: null,
    };
    mockEvents = [{ type: "routing", metadata }, { type: "done" }];

    const { result } = renderHook(() => useChat());

    await act(async () => {
      await result.current.sendMessage("explain quantum physics");
    });

    expect(result.current.messages[1].routing).toEqual(metadata);
  });

  it("sets isStreaming false after done", async () => {
    mockEvents = [{ type: "done" }];

    const { result } = renderHook(() => useChat());

    await act(async () => {
      await result.current.sendMessage("test");
    });

    expect(result.current.isStreaming).toBe(false);
    expect(result.current.messages[1].isStreaming).toBe(false);
  });

  it("handles error event", async () => {
    mockEvents = [
      { type: "error", message: "something broke" },
      { type: "done" },
    ];

    const { result } = renderHook(() => useChat());

    await act(async () => {
      await result.current.sendMessage("test");
    });

    expect(result.current.messages[1].content).toBe("something broke");
    expect(result.current.messages[1].isStreaming).toBe(false);
  });

  it("ignores empty input", async () => {
    const { result } = renderHook(() => useChat());

    await act(async () => {
      await result.current.sendMessage("");
      await result.current.sendMessage("   ");
    });

    expect(result.current.messages).toHaveLength(0);
  });
});
