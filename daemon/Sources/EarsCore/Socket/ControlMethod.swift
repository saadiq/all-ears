/// Every v2 method name, with the capability each requires
/// (`docs/specs/control-protocol.md`'s "Methods" table). `hello` is
/// the one method with no capability — it *establishes* the connection's
/// capabilities.
public enum ControlMethod: String, Sendable, Hashable, Codable, CaseIterable {
  case hello

  case status
  case subscribe

  // The raw strings are the v2 wire method names and deliberately still say
  // "meeting" — the wire rename happens in the lockstep daemon+extension
  // change (#47), so the extension keeps working against this build.
  case sessionStart = "meeting.start"
  case sessionEnd = "meeting.end"
  case sessionPause = "meeting.pause"
  case sessionResume = "meeting.resume"
  case sessionRename = "meeting.rename"
  case sessionAttendee = "meeting.attendee"
  case sessionList = "meeting.list"
  case sessionGet = "meeting.get"

  case segmentPublish = "segment.publish"
  case jobPublish = "job.publish"

  case sourcesList = "sources.list"
  case sourcesEnable = "sources.enable"
  case sourcesDisable = "sources.disable"

  case sourcesAdd = "sources.add"
  case sourcesRemove = "sources.remove"
  case capturePause = "capture.pause"
  case captureResume = "capture.resume"
  case flush

  /// The capability a connection needs to invoke this method; `nil` only for
  /// `hello`. Transports enforce this before dispatch (`not_permitted`).
  public var capability: Capability? {
    switch self {
    case .hello:
      return nil
    case .status, .subscribe:
      return .observe
    case .sessionStart, .sessionEnd, .sessionPause, .sessionResume, .sessionRename,
      .sessionAttendee, .sessionList, .sessionGet:
      return .sessions
    case .segmentPublish, .jobPublish:
      return .publish
    case .sourcesList, .sourcesEnable, .sourcesDisable:
      return .sources
    case .sourcesAdd, .sourcesRemove, .capturePause, .captureResume, .flush:
      return .admin
    }
  }
}
