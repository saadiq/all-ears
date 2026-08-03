/// `status`'s result payload: daemon + per-source state (with buffer
/// occupancy, see ``SourceStatus``), plus the active meetings — v2 widened
/// the v1 shape with the `meetings` list.
public struct StatusData: Sendable, Hashable, Codable {
  public var uptimeSeconds: Int
  public var sources: [SourceStatus]
  public var meetings: [Meeting]

  public init(uptimeSeconds: Int, sources: [SourceStatus], meetings: [Meeting] = []) {
    self.uptimeSeconds = uptimeSeconds
    self.sources = sources
    self.meetings = meetings
  }

  private enum CodingKeys: String, CodingKey {
    case uptimeSeconds = "uptime_s"
    case sources, meetings
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    uptimeSeconds = try container.decode(Int.self, forKey: .uptimeSeconds)
    sources = try container.decode([SourceStatus].self, forKey: .sources)
    meetings = try container.decodeIfPresent([Meeting].self, forKey: .meetings) ?? []
  }
}
