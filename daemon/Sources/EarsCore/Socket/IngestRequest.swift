/// The ingest WebSocket's text-frame commands — the **v1 ingest
/// contract** (`/ingest` is explicitly out of control protocol v2's scope): a
/// flat `cmd`-tagged envelope, answered with the `{"ok":…}` ``ControlResponse``
/// shape.
///
/// ```jsonc
/// {"cmd":"ingest.open","source":"browser:meet","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
/// {"cmd":"ingest.open","source":"browser:meet:dev-2","format":{…},"session":{"platform":"meet","external_id":"kQ0DRVtDaekB"}}
/// {"cmd":"ingest.close","stream_id":"s7"}
/// {"cmd":"ingest.attribution","session":{…},"events":["{\"schema\":1,…}",…]}
/// ```
///
/// `session` is optional on `open`: when present, the daemon links the source
/// into that session's membership itself (see
/// `SessionRegistry.ingestStreamOpened`), so the ingest-idle grace policy
/// holds even when the client's own `session.attendee` source upserts never
/// arrive (an MV3 service worker that lost its in-memory state mid-call).
/// Untagged opens behave exactly as before.
///
/// `attribution` carries a batch of the extension's attribution
/// flight-recorder events (`docs/specs/browser/transport.md`): each element
/// is one pre-encoded JSONL line the daemon appends verbatim to the tagged
/// session's `attribution.jsonl`. The tag is mandatory here — a batch with no
/// session has no directory to land in.
public enum IngestRequest: Sendable, Hashable {
  /// Begin pushing audio for a `browser:<label>` source; declares its format
  /// and (optionally) the session identity the source belongs to.
  case open(source: SourceID, format: AudioFormatSpec, session: SessionIdentity?)
  /// End a stream opened by `ingest.open`, by its `stream_id`.
  case close(streamID: String)
  /// A batch of attribution flight-recorder lines for the tagged session.
  case attribution(session: SessionIdentity, events: [String])
}

extension IngestRequest: Codable {
  private enum CodingKeys: String, CodingKey {
    case cmd, source, format
    case session
    case streamID = "stream_id"
    case events
  }

  private enum Tag: String, Codable {
    case open = "ingest.open"
    case close = "ingest.close"
    case attribution = "ingest.attribution"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Tag.self, forKey: .cmd) {
    case .open:
      self = .open(
        source: try container.decode(SourceID.self, forKey: .source),
        format: try container.decode(AudioFormatSpec.self, forKey: .format),
        session: try container.decodeIfPresent(SessionIdentity.self, forKey: .session))
    case .close:
      self = .close(streamID: try container.decode(String.self, forKey: .streamID))
    case .attribution:
      self = .attribution(
        session: try container.decode(SessionIdentity.self, forKey: .session),
        events: try container.decode([String].self, forKey: .events))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .open(let source, let format, let session):
      try container.encode(Tag.open, forKey: .cmd)
      try container.encode(source, forKey: .source)
      try container.encode(format, forKey: .format)
      try container.encodeIfPresent(session, forKey: .session)
    case .close(let streamID):
      try container.encode(Tag.close, forKey: .cmd)
      try container.encode(streamID, forKey: .streamID)
    case .attribution(let session, let events):
      try container.encode(Tag.attribution, forKey: .cmd)
      try container.encode(session, forKey: .session)
      try container.encode(events, forKey: .events)
    }
  }
}
