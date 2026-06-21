import type { StreamEvent } from "../types/chat";

const API_BASE = import.meta.env.VITE_API_URL || "";

const VALID_EVENT_TYPES = new Set(["routing", "delta", "error", "done"]);

function isStreamEvent(data: unknown): data is StreamEvent {
  return typeof data === "object" && data !== null && "type" in data && VALID_EVENT_TYPES.has((data as StreamEvent).type);
}

export async function* streamChat(
  messages: Array<{ role: string; content: string }>,
  signal?: AbortSignal,
): AsyncGenerator<StreamEvent> {
  const response = await fetch(`${API_BASE}/api/v1/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ messages }),
    signal,
  });

  if (!response.ok) {
    yield { type: "error", message: `API error: ${response.status}` };
    yield { type: "done" };
    return;
  }

  const reader = response.body?.getReader();
  if (!reader) {
    yield { type: "error", message: "No response stream" };
    yield { type: "done" };
    return;
  }

  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n\n");
    buffer = lines.pop() || "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("data: ")) continue;
      const payload = trimmed.slice(6);
      try {
        const parsed: unknown = JSON.parse(payload);
        if (isStreamEvent(parsed)) yield parsed;
      } catch {
        // skip malformed lines
      }
    }
  }

  if (buffer.trim().startsWith("data: ")) {
    try {
      const parsed: unknown = JSON.parse(buffer.trim().slice(6));
      if (isStreamEvent(parsed)) yield parsed;
    } catch {
      // skip
    }
  }
}
