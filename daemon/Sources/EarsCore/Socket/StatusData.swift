/// `status`'s result payload: daemon + per-source state (with buffer
/// occupancy, see ``SourceStatus``), plus the active sessions — v2 widened
/// the v1 shape with the `meetings` list.
public struct StatusData: Sendable, Hashable, Codable {
  public var uptimeSeconds: Int
  public var sources: [SourceStatus]
  public var sessions: [Session]

  public init(uptimeSeconds: Int, sources: [SourceStatus], sessions: [Session] = []) {
    self.uptimeSeconds = uptimeSeconds
    self.sources = sources
    self.sessions = sessions
  }

  private enum CodingKeys: String, CodingKey {
    case uptimeSeconds = "uptime_s"
    case sources
    // `sessions` is the wire's `meetings` key until the wire rename (#47).
    case sessions = "meetings"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    uptimeSeconds = try container.decode(Int.self, forKey: .uptimeSeconds)
    sources = try container.decode([SourceStatus].self, forKey: .sources)
    sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
  }
}
