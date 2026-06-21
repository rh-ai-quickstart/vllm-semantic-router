import { useEffect, useRef, useState } from "react";
import type { ChatMessage } from "../types/chat";
import { MessageBubble } from "./MessageBubble";

interface Props {
  messages: ChatMessage[];
  isStreaming: boolean;
  selectedMessageId: string | null;
  onSelectMessage: (id: string) => void;
  onSendMessage: (text: string) => void;
}

export function ChatPanel({
  messages,
  isStreaming,
  selectedMessageId,
  onSelectMessage,
  onSendMessage,
}: Props) {
  const [input, setInput] = useState("");
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!input.trim() || isStreaming) return;
    onSendMessage(input);
    setInput("");
  };

  return (
    <div className="chat-panel">
      <div className="messages-container">
        {messages.length === 0 && (
          <div className="messages-empty">
            <h2>vLLM Semantic Router</h2>
            <p>Send a message to see intelligent routing in action.</p>
            <div className="suggestions">
              <button onClick={() => onSendMessage("Explain quantum entanglement in detail")} type="button">
                Research query
              </button>
              <button onClick={() => onSendMessage("What is Red Hat OpenShift AI?")} type="button">
                Knowledge base query
              </button>
              <button onClick={() => onSendMessage("Hello, how are you?")} type="button">
                General chat
              </button>
            </div>
          </div>
        )}
        {messages.map((msg) => (
          <MessageBubble
            key={msg.id}
            message={msg}
            isSelected={msg.id === selectedMessageId}
            onSelect={() => onSelectMessage(msg.id)}
          />
        ))}
        <div ref={bottomRef} />
      </div>

      <form className="input-area" onSubmit={handleSubmit}>
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Type a message..."
          maxLength={32000}
          disabled={isStreaming}
          className="chat-input"
        />
        <button type="submit" disabled={isStreaming || !input.trim()} className="send-button">
          Send
        </button>
      </form>
    </div>
  );
}
