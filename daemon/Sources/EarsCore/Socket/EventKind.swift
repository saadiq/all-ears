/// A v2 notification kind — the `event` discriminator of an ``EventFrame``.
///
/// Two classes (`docs/specs/control-protocol.md`'s "State sync"):
/// *state* events (``session``, ``source``) mutate the synced state, carry
/// `rev`, and are always delivered to every subscriber; *telemetry* events
/// (``vad``, ``segment``, ``job``, ``meetingActivity``) are fire-and-forget,
/// carry no `rev`, and are what `subscribe`'s `events`/`sources` filter.
public enum EventKind: String, Sendable, Hashable, Codable, CaseIterable {
  case vad
  case segment
  case session
  case source
  case job
  case meetingActivity = "meeting.activity"

  /// Whether this kind participates in state sync (revision-tagged,
  /// unconditionally delivered).
  public var isState: Bool {
    switch self {
    case .session, .source: true
    case .vad, .segment, .job, .meetingActivity: false
    }
  }
}
