import type { RoutingMetadata } from "../types/chat";

interface Props {
  metadata: RoutingMetadata | undefined;
}

export function RoutingSidebar({ metadata }: Props) {
  if (!metadata) {
    return (
      <aside className="sidebar">
        <h2>Routing Preview</h2>
        <p className="sidebar-empty">Select a message to see routing details.</p>
      </aside>
    );
  }

  return (
    <aside className="sidebar">
      <h2>Routing Preview</h2>

      <p className="sidebar-empty">Preview selection; the model serving the answer may differ.</p>

      <div className="sidebar-section">
        <h3>Decision</h3>
        <div className="sidebar-value">{metadata.selected_decision || "—"}</div>
        {metadata.selected_confidence != null && (
          <div className="confidence-bar">
            <div
              className="confidence-fill"
              style={{ width: `${Math.round(metadata.selected_confidence * 100)}%` }}
            />
            <span className="confidence-label">
              {Math.round(metadata.selected_confidence * 100)}%
            </span>
          </div>
        )}
      </div>

      <div className="sidebar-section">
        <h3>Model</h3>
        <div className="sidebar-value">{metadata.selected_model || "—"}</div>
      </div>

      {metadata.signal_confidences && Object.keys(metadata.signal_confidences).length > 0 && (
        <div className="sidebar-section">
          <h3>Signal Confidences</h3>
          <ul className="signal-list">
            {Object.entries(metadata.signal_confidences).map(([signal, score]) => (
              <li key={signal} className="signal-item">
                <span className="signal-name">{signal}</span>
                <span className="signal-score">{(score * 100).toFixed(0)}%</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {metadata.matched_signals && Object.keys(metadata.matched_signals).length > 0 && (
        <div className="sidebar-section">
          <h3>Matched Signals</h3>
          <ul className="signal-list">
            {Object.entries(metadata.matched_signals).map(([type, signals]) => (
              <li key={type} className="signal-item">
                <span className="signal-name">{type}</span>
                <span className="signal-score">{signals.join(", ")}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {metadata.routing_decision && (
        <div className="sidebar-section">
          <h3>Routing Decision</h3>
          <div className="sidebar-value">{metadata.routing_decision}</div>
        </div>
      )}
    </aside>
  );
}
