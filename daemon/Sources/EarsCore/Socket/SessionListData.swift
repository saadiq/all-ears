/// `session.list`'s result: active + recent sessions. Closed history is read
/// from disk (`ears session list --all`), not the socket.
public struct SessionListData: Sendable, Hashable, Codable {
  public var sessions: [Session]

  public init(sessions: [Session]) {
    self.sessions = sessions
  }

  private enum CodingKeys: String, CodingKey {
    case sessions
  }
}
