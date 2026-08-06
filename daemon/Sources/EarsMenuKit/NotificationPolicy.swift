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

  public static func onDisconnect(state: MenuState) -> NotificationRequest? {
    guard let session = state.activeSession else { return nil }
    return NotificationRequest(
      title: "Recording at risk",
      body: "earsd stopped while '\(session.title)' was recording.", action: .none)
  }

  private static func sessionTitle(_ id: String?, in state: MenuState) -> String {
    guard let id else { return "session" }
    return state.sessions.first { $0.id == id }?.title ?? String(id.prefix(8))
  }
}
