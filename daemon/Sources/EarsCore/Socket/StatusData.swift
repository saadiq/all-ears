/// `status`'s result payload: daemon + per-source state (with buffer
/// occupancy, see ``SourceStatus``), plus the active sessions — v2 widened
/// the v1 shape with the `sessions` list.
public struct StatusData: Sendable, Hashable, Codable {
  public var uptimeSeconds: Int
  public var sources: [SourceStatus]
  public var sessions: [Session]
  /// What this daemon was configured with at boot: the capturable
  /// config-declared sources in declaration order, and the resolved
  /// `[earsd.sessions] on_end_stages` chain. A client that starts a manual
  /// session declares these instead of parsing daemon config, so what it
  /// asks for is what this daemon will actually capture and run.
  public var configured: Configured?

  public init(
    uptimeSeconds: Int, sources: [SourceStatus], sessions: [Session] = [],
    configured: Configured? = nil
  ) {
    self.uptimeSeconds = uptimeSeconds
    self.sources = sources
    self.sessions = sessions
    self.configured = configured
  }

  private enum CodingKeys: String, CodingKey {
    case uptimeSeconds = "uptime_s"
    case sources
    case sessions
    case configured
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    uptimeSeconds = try container.decode(Int.self, forKey: .uptimeSeconds)
    sources = try container.decode([SourceStatus].self, forKey: .sources)
    sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
    configured = try container.decodeIfPresent(Configured.self, forKey: .configured)
  }
}

extension StatusData {
  public struct Configured: Sendable, Hashable, Codable {
    public var sources: [SourceID]
    public var onEndStages: [String]

    public init(sources: [SourceID], onEndStages: [String]) {
      self.sources = sources
      self.onEndStages = onEndStages
    }

    private enum CodingKeys: String, CodingKey {
      case sources
      case onEndStages = "on_end_stages"
    }
  }
}
