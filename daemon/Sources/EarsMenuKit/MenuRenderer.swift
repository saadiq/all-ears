import EarsCore

public enum MenuRenderer {
  public static func render(_ state: MenuState, now: Instant) -> MenuContent {
    MenuContent(
      icon: icon(for: state), header: header(for: state, now: now),
      verbs: verbs(for: state), pipeline: pipeline(for: state))
  }

  static func icon(for state: MenuState) -> IconVariant {
    if state.connection == .unreachable { return .attention }
    if let active = state.activeSession {
      return active.state == .paused ? .paused : .recording
    }
    if !state.failedJobs.isEmpty { return .attention }
    if !state.runningJobs.isEmpty { return .busy }
    return .idle
  }

  static func header(for state: MenuState, now: Instant) -> String {
    switch state.connection {
    case .connecting: return "Connecting to earsd…"
    case .unreachable: return "⚠ Daemon not running"
    case .connected: break
    }
    guard let session = state.activeSession else { return "Idle" }
    let elapsed = ElapsedFormatter.clock(now.interval(since: session.started))
    let mark = session.state == .paused ? "⏸ Paused" : "● Recording"
    return "\(mark) · \(session.title) · \(elapsed)"
  }

  static func verbs(for state: MenuState) -> [Verb] {
    guard state.connection == .connected else { return [] }
    guard let session = state.activeSession else { return [.startRecording] }
    let toggle: Verb =
      session.state == .paused ? .resume(session: session.id) : .pause(session: session.id)
    return [
      toggle, .rename(session: session.id, currentTitle: session.title), .end(session: session.id),
    ]
  }

  static func pipeline(for state: MenuState) -> [PipelineLine] {
    state.jobs.map { job in
      let title =
        state.sessions.first { $0.id == job.session }?.title
        ?? job.session.map { String($0.prefix(8)) } ?? "session"
      switch job.state {
      case .started, .running:
        return PipelineLine(text: "\(progressLabel(job.kind)) '\(title)'…")
      case .failed:
        return PipelineLine(
          text: "⚠ \(stageLabel(job.kind)) failed — \(title)", dismissibleJobID: job.job)
      case .done:
        return PipelineLine(text: "\(stageLabel(job.kind)) done — \(title)")
      }
    }
  }

  static func progressLabel(_ kind: String) -> String {
    switch kind {
    case "transcribe": return "Transcribing"
    case "cleanup": return "Cleaning up"
    case "summarize": return "Summarizing"
    default: return kind
    }
  }

  static func stageLabel(_ kind: String) -> String {
    switch kind {
    case "transcribe": return "Transcription"
    case "cleanup": return "Cleanup"
    case "summarize": return "Summary"
    default: return kind
    }
  }
}
