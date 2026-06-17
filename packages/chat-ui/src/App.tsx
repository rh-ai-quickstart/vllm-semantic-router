import { ErrorBoundary } from "react-error-boundary";
import { ChatPanel } from "./components/ChatPanel";
import { RoutingSidebar } from "./components/RoutingSidebar";
import { useChat } from "./hooks/useChat";

function ErrorFallback() {
  return (
    <div style={{ padding: "2rem", textAlign: "center" }}>
      <h2>Something went wrong.</h2>
      <button onClick={() => window.location.reload()}>Refresh</button>
    </div>
  );
}

export default function App() {
  const { messages, isStreaming, selectedMessageId, setSelectedMessageId, sendMessage } = useChat();

  const selectedMessage = messages.find((m) => m.id === selectedMessageId);

  return (
    <ErrorBoundary FallbackComponent={ErrorFallback}>
      <div className="app">
        <header className="app-header">
          <h1>vLLM Semantic Router</h1>
          <span className="app-subtitle">Intelligent multi-agent routing demo</span>
        </header>
        <main className="app-main">
          <ChatPanel
            messages={messages}
            isStreaming={isStreaming}
            selectedMessageId={selectedMessageId}
            onSelectMessage={setSelectedMessageId}
            onSendMessage={sendMessage}
          />
          <RoutingSidebar metadata={selectedMessage?.routing} />
        </main>
      </div>
    </ErrorBoundary>
  );
}
