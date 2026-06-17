import { useCallback, useRef, useState } from "react";
import { streamChat } from "../services/api";
import type { ChatMessage } from "../types/chat";

let nextId = 0;

export function useChat() {
  const [messages, _setMessages] = useState<ChatMessage[]>([]);
  const messagesRef = useRef<ChatMessage[]>([]);
  const setMessages = useCallback(
    (update: ChatMessage[] | ((prev: ChatMessage[]) => ChatMessage[])) => {
      _setMessages((prev) => {
        const next = typeof update === "function" ? update(prev) : update;
        messagesRef.current = next;
        return next;
      });
    },
    [],
  );
  const [isStreaming, _setIsStreaming] = useState(false);
  const isStreamingRef = useRef(false);
  const setIsStreaming = useCallback((value: boolean) => {
    isStreamingRef.current = value;
    _setIsStreaming(value);
  }, []);
  const [selectedMessageId, setSelectedMessageId] = useState<string | null>(null);
  const sendMessage = useCallback(
    async (text: string) => {
      if (!text.trim() || isStreamingRef.current) return;

      const userMsg: ChatMessage = {
        id: String(nextId++),
        role: "user",
        content: text.trim(),
      };

      const assistantId = String(nextId++);
      const assistantMsg: ChatMessage = {
        id: assistantId,
        role: "assistant",
        content: "",
        isStreaming: true,
      };

      setMessages((prev) => [...prev, userMsg, assistantMsg]);
      setSelectedMessageId(assistantId);
      setIsStreaming(true);

      const history = [...messagesRef.current.filter((m) => !m.isStreaming)].map((m) => ({
        role: m.role,
        content: m.content,
      }));

      try {
        for await (const event of streamChat(history)) {
          switch (event.type) {
            case "routing":
              setMessages((prev) =>
                prev.map((m) => (m.id === assistantId ? { ...m, routing: event.metadata } : m)),
              );
              break;

            case "delta":
              setMessages((prev) =>
                prev.map((m) =>
                  m.id === assistantId ? { ...m, content: m.content + event.content } : m,
                ),
              );
              break;

            case "error":
              setMessages((prev) =>
                prev.map((m) =>
                  m.id === assistantId
                    ? { ...m, content: event.message, isStreaming: false }
                    : m,
                ),
              );
              break;

            case "done":
              setMessages((prev) =>
                prev.map((m) => (m.id === assistantId ? { ...m, isStreaming: false } : m)),
              );
              break;
          }
        }
      } catch (err) {
        setMessages((prev) =>
          prev.map((m) =>
            m.id === assistantId
              ? { ...m, content: `Connection error: ${err}`, isStreaming: false }
              : m,
          ),
        );
      } finally {
        setIsStreaming(false);
      }
    },
    [],
  );

  return {
    messages,
    isStreaming,
    selectedMessageId,
    setSelectedMessageId,
    sendMessage,
  };
}
