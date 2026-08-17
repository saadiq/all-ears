/// `status`'s result payload: daemon + per-source state (with buffer
/// occupancy, see ``SourceStatus``), plus the active sessions — v2 widened
/// the v1 shape with the `sessions` list.
public struct StatusData: Sendable, Hashable, Codable {
  public var uptimeSeconds: Int
  public var sources: [SourceStatus]
  public var sessions: [Session]
  public var meetingActivity: [MeetingActivityStatus]

  public init(
    uptimeSeconds: Int, sources: [SourceStatus], sessions: [Session] = [],
    meetingActivity: [MeetingActivityStatus] = []
  ) {
    self.uptimeSeconds = uptimeSeconds
    self.sources = sources
    self.sessions = sessions
    self.meetingActivity = meetingActivity
  }

  private enum CodingKeys: String, CodingKey {
    case uptimeSeconds = "uptime_s"
    case sources
    case sessions
    case meetingActivity = "meeting_activity"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    uptimeSeconds = try container.decode(Int.self, forKey: .uptimeSeconds)
    sources = try container.decode([SourceStatus].self, forKey: .sources)
    sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
    meetingActivity =
      try container.decodeIfPresent([MeetingActivityStatus].self, forKey: .meetingActivity) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(uptimeSeconds, forKey: .uptimeSeconds)
    try container.encode(sources, forKey: .sources)
    try container.encode(sessions, forKey: .sessions)
    if !meetingActivity.isEmpty {
      try container.encode(meetingActivity, forKey: .meetingActivity)
    }
  }
}
