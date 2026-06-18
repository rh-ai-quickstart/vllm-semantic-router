import { describe, expect, it, vi, beforeEach } from "vitest";
import { streamChat } from "../src/services/api";

function makeSSE(...events: object[]): string {
  return events.map((e) => `data: ${JSON.stringify(e)}`).join("\n\n") + "\n\n";
}

function mockFetchStream(body: string, status = 200) {
  const encoder = new TextEncoder();
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(body));
      controller.close();
    },
  });

  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: status >= 200 && status < 300,
      status,
      body: stream,
    }),
  );
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("streamChat", () => {
  it("yields routing, delta, and done events", async () => {
    const sseBody = makeSSE(
      { type: "routing", metadata: { selected_decision: "general" } },
      { type: "delta", content: "Hello" },
      { type: "delta", content: " world" },
      { type: "done" },
    );
    mockFetchStream(sseBody);

    const events = [];
    for await (const event of streamChat([{ role: "user", content: "hi" }])) {
      events.push(event);
    }

    expect(events).toHaveLength(4);
    expect(events[0]).toEqual({ type: "routing", metadata: { selected_decision: "general" } });
    expect(events[1]).toEqual({ type: "delta", content: "Hello" });
    expect(events[2]).toEqual({ type: "delta", content: " world" });
    expect(events[3]).toEqual({ type: "done" });
  });

  it("yields error + done on non-200 response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({ ok: false, status: 500 }),
    );

    const events = [];
    for await (const event of streamChat([{ role: "user", content: "hi" }])) {
      events.push(event);
    }

    expect(events).toHaveLength(2);
    expect(events[0]).toEqual({ type: "error", message: "API error: 500" });
    expect(events[1]).toEqual({ type: "done" });
  });

  it("yields error + done when body is null", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({ ok: true, status: 200, body: null }),
    );

    const events = [];
    for await (const event of streamChat([{ role: "user", content: "hi" }])) {
      events.push(event);
    }

    expect(events).toHaveLength(2);
    expect(events[0]).toEqual({ type: "error", message: "No response stream" });
    expect(events[1]).toEqual({ type: "done" });
  });

  it("skips malformed JSON lines", async () => {
    const body = 'data: {bad json}\n\ndata: {"type":"done"}\n\n';
    mockFetchStream(body);

    const events = [];
    for await (const event of streamChat([{ role: "user", content: "hi" }])) {
      events.push(event);
    }

    expect(events).toHaveLength(1);
    expect(events[0]).toEqual({ type: "done" });
  });

  it("handles chunked delivery across buffer boundary", async () => {
    const encoder = new TextEncoder();
    const chunk1 = 'data: {"type":"del';
    const chunk2 = 'ta","content":"Hi"}\n\ndata: {"type":"done"}\n\n';

    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(encoder.encode(chunk1));
        controller.enqueue(encoder.encode(chunk2));
        controller.close();
      },
    });

    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({ ok: true, status: 200, body: stream }),
    );

    const events = [];
    for await (const event of streamChat([{ role: "user", content: "hi" }])) {
      events.push(event);
    }

    expect(events).toHaveLength(2);
    expect(events[0]).toEqual({ type: "delta", content: "Hi" });
    expect(events[1]).toEqual({ type: "done" });
  });

  it("sends messages array in request body", async () => {
    const sseBody = makeSSE({ type: "done" });
    mockFetchStream(sseBody);

    const messages = [
      { role: "user", content: "hello" },
      { role: "assistant", content: "hi" },
      { role: "user", content: "how are you" },
    ];

    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    for await (const _event of streamChat(messages)) {
      // consume
    }

    const fetchCall = vi.mocked(fetch).mock.calls[0];
    const body = JSON.parse(fetchCall[1]?.body as string);
    expect(body.messages).toEqual(messages);
  });
});
