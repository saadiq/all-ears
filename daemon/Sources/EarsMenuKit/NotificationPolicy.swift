import EarsCore

public struct NotificationRequest: Sendable, Hashable {
  public enum Action: Sendable, Hashable {
    case openSummary(session: String)
    case revealSession(session: String)
    case none
  }
  public var title: String
  public var body: String
  public var action: Action
  public init(title: String, body: String, action: Action) {
    self.title = title
    self.body = body
    self.action = action
  }
}

public enum NotificationPolicy {
  public static func onEvent(_ frame: EventFrame, state: MenuState) -> NotificationRequest? {
    guard case .job(let job) = frame.event else { return nil }
    let title = sessionTitle(job.session, in: state)
    switch (job.kind, job.state) {
    case ("summarize", .done):
      return NotificationRequest(
        title: "Summary ready", body: title,
        action: job.session.map { .openSummary(session: $0) } ?? .none)
    case (_, .failed):
      return NotificationRequest(
        title: "\(MenuRenderer.stageLabel(job.kind)) failed", body: title,
        action: job.session.map { .revealSession(session: $0) } ?? .none)
    default:
      return nil
    }
  }

  /// Edge-triggered: fires only on the transition into disconnection, not on every
  /// redial failure while already unreachable. The pump calls this before reducing,
  /// so any state but `.unreachable` means this is the drop itself; once
  /// `disconnected()` has flipped `state.connection`, subsequent redial failures stay
  /// quiet until the next successful reconnect re-arms the warning.
  ///
  /// `.connecting` has to arm it too, not just `.connected`: a rev gap bounces
  /// the socket through `resubscribing()`, which parks the state at
  /// `.connecting` while the redial is in flight. Gating on `.connected` alone
  /// meant a daemon that died during that window — a dropped frame *because*
  /// the daemon was in trouble is the likely case, not a coincidence — warned
  /// about nothing at all, leaving the menu bar glyph as the only signal that
  /// a recording had stopped.
  ///
  /// The edge alone is not enough: a crash-looping daemon reconnects between
  /// crashes, re-arming the edge every second or so, and each post carries a
  /// fresh identifier that macOS will not coalesce. `warnedSessions` therefore
  /// carries the sessions already warned about, making the warning once per
  /// at-risk session rather than once per crash.
  public static func onDisconnect(
    state: MenuState, warnedSessions: Set<String> = []
  ) -> NotificationRequest? {
    guard state.connection != .unreachable else { return nil }
    guard let session = state.activeSession, !warnedSessions.contains(session.id) else {
      return nil
    }
    return NotificationRequest(
      title: "Recording at risk",
      body: "earsd stopped while ‘\(session.title)’ was recording.", action: .none)
  }

  private static func sessionTitle(_ id: String?, in state: MenuState) -> String {
    guard let id else { return "session" }
    return state.sessions.first { $0.id == id }?.title ?? String(id.prefix(8))
  }
}
