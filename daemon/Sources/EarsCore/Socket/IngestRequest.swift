/// The ingest WebSocket's text-frame commands — the **v1 ingest
/// contract** (`/ingest` is explicitly out of control protocol v2's scope): a
/// flat `cmd`-tagged envelope, answered with the `{"ok":…}` ``ControlResponse``
/// shape.
///
/// ```jsonc
/// {"cmd":"ingest.open","source":"browser:meet","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
/// {"cmd":"ingest.open","id":"7","source":"browser:meet:dev-2","format":{…},"session":{"platform":"meet","external_id":"kQ0DRVtDaekB"}}
/// {"cmd":"ingest.close","id":"8","stream_id":"s7"}
/// {"cmd":"ingest.attribution","session":{…},"events":["{\"schema\":1,…}",…]}
/// ```
///
/// `id` is the client's optional correlation id (an opaque string). The
/// daemon echoes it verbatim on the command's reply (see ``IngestReply``) so
/// the client can match replies by id instead of relying on request order;
/// a request without one gets a reply without one, and such clients keep
/// matching FIFO exactly as before the field existed.
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
  case open(source: SourceID, format: AudioFormatSpec, session: SessionIdentity?, id: String?)
  /// End a stream opened by `ingest.open`, by its `stream_id`.
  case close(streamID: String, id: String?)
  /// A batch of attribution flight-recorder lines for the tagged session.
  case attribution(session: SessionIdentity, events: [String], id: String?)

  /// The correlation id to echo on this request's reply, when the client sent one.
  public var correlationID: String? {
    switch self {
    case .open(_, _, _, let id), .close(_, let id), .attribution(_, _, let id):
      return id
    }
  }
}

extension IngestRequest: Codable {
  private enum CodingKeys: String, CodingKey {
    case cmd, source, format
    case session
    case streamID = "stream_id"
    case events
    case id
  }

  private enum Tag: String, Codable {
    case open = "ingest.open"
    case close = "ingest.close"
    case attribution = "ingest.attribution"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decodeIfPresent(String.self, forKey: .id)
    switch try container.decode(Tag.self, forKey: .cmd) {
    case .open:
      self = .open(
        source: try container.decode(SourceID.self, forKey: .source),
        format: try container.decode(AudioFormatSpec.self, forKey: .format),
        session: try container.decodeIfPresent(SessionIdentity.self, forKey: .session),
        id: id)
    case .close:
      self = .close(streamID: try container.decode(String.self, forKey: .streamID), id: id)
    case .attribution:
      self = .attribution(
        session: try container.decode(SessionIdentity.self, forKey: .session),
        events: try container.decode([String].self, forKey: .events),
        id: id)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(correlationID, forKey: .id)
    switch self {
    case .open(let source, let format, let session, _):
      try container.encode(Tag.open, forKey: .cmd)
      try container.encode(source, forKey: .source)
      try container.encode(format, forKey: .format)
      try container.encodeIfPresent(session, forKey: .session)
    case .close(let streamID, _):
      try container.encode(Tag.close, forKey: .cmd)
      try container.encode(streamID, forKey: .streamID)
    case .attribution(let session, let events, _):
      try container.encode(Tag.attribution, forKey: .cmd)
      try container.encode(session, forKey: .session)
      try container.encode(events, forKey: .events)
    }
  }
}
