/// What started a session, recorded as its `trigger` provenance field.
public enum TriggerKind: String, Sendable, Hashable, Codable, CaseIterable {
  /// Started by an explicit user action.
  case manual
  /// Started by the browser extension over the control-plane WebSocket (e.g.
  /// a Google Meet call starting in a tab) — not a literal CLI invocation, so
  /// it gets its own provenance value.
  case browserExtension = "browser-extension"
  /// Started from the menu bar's detect-and-prompt flow for a native app
  /// meeting (a configured `app:*` source began using the microphone). Its
  /// own provenance value because two policies key off it: these sessions
  /// inherit the configured on-end chain, and the daemon auto-ends them once
  /// the app's audio activity stays quiet past `[earsd.detection] idle_grace_s`.
  case appDetected = "app-detected"
}
