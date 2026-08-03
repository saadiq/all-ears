/// What started a meeting, recorded as its `trigger` provenance field.
public enum TriggerKind: String, Sendable, Hashable, Codable, CaseIterable {
  /// Started by an explicit user action.
  case manual
  /// Started by the browser extension over the control-plane WebSocket (e.g.
  /// a Google Meet call starting in a tab) — not a literal CLI invocation, so
  /// it gets its own provenance value.
  case browserExtension = "browser-extension"
}
