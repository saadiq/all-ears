import EarsCore

public struct NotificationRequest: Sendable, Hashable {
  public enum Action: Sendable, Hashable {
    /// Open the session's summary. `path` is the file the daemon reported
    /// writing, when it reported one.
    case openSummary(session: String, path: String?)
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
  /// - Parameter state: the menu state *before* `frame` is applied. A job
  ///   already failed there has been announced: the daemon re-states a
  ///   transcribe failure under the child's own job id, and that second
  ///   frame is not news.
  public static func onEvent(_ frame: EventFrame, state: MenuState) -> NotificationRequest? {
    guard case .job(let job) = frame.event else { return nil }
    if job.state == .failed, state.failedJobs.contains(where: { $0.job == job.job }) {
      return nil
    }
    let title = state.title(ofSession: job.session)
    switch (job.kind, job.state) {
    case ("summarize", .done):
      // Attribution warnings ride the summary's own notification rather than
      // getting one of their own. They are the failure that looks like
      // success — the note is there and reads fine, but a name on it may be
      // the wrong person's — and `RosterReconciler` already writes them into
      // that same note, so this is the moment the user is about to open the
      // file the warning is about. A session the menu never saw reports no
      // warnings, which degrades to the plain notice rather than implying
      // attribution was clean.
      let warnings = session(job.session, in: state)?.warnings ?? []
      return NotificationRequest(
        title: warnings.isEmpty ? "Summary ready" : "Summary ready — check speaker names",
        body: body(title: title, warnings: warnings),
        action: job.session.map { .openSummary(session: $0, path: job.outputs?.first) } ?? .none)
    case (_, .failed):
      return NotificationRequest(
        title: "\(MenuRenderer.stageLabel(job.kind)) failed", body: title,
        action: job.session.map { .revealSession(session: $0) } ?? .none)
    default:
      return nil
    }
  }

  /// Edge-triggered: fires only on the transition into disconnection, not on
  /// every redial failure while already unreachable. The pump calls this
  /// before reducing, so any state but `.unreachable` means this is the drop
  /// itself.
  ///
  /// `.connecting` arms it as well as `.connected`: a rev gap parks the state
  /// at `.connecting` while the socket is redialled, and a daemon in enough
  /// trouble to drop a frame is the likely one to die in that window.
  ///
  /// `warnedSessions` makes it once per at-risk session: a crash-looping
  /// daemon reconnects between crashes, re-arming the edge each time, and
  /// macOS will not coalesce posts with fresh identifiers.
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

  /// The session title plus the first warning, since a notification body
  /// shows a couple of lines and the reconciler's warnings are full
  /// sentences. The rest are counted, not quoted — every one of them is
  /// written into the summary the click opens.
  private static func body(title: String, warnings: [String]) -> String {
    guard let first = warnings.first else { return title }
    let remainder = warnings.count - 1
    let more = remainder > 0 ? " (+\(remainder) more)" : ""
    return "\(title) — \(first)\(more)"
  }

  private static func session(_ id: String?, in state: MenuState) -> Session? {
    guard let id else { return nil }
    return state.sessions.first { $0.id == id }
  }
}
