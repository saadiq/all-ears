/// One live-feed notification's payload, discriminated on the wire by the
/// envelope's `event` field (see ``EventFrame``):
///
/// ```jsonc
/// {"event":"meeting","params":{"meeting":{…}},"rev":42}
/// {"event":"source","params":{"id":"mic","state":"paused"},"rev":44}
/// {"event":"vad","params":{"source":"mic","state":"speech","t":"…"}}
/// {"event":"segment","params":{"meeting":"…","speaker":"You","start":604.1,"end":611.9,"text":"…"}}
/// {"event":"job","params":{"job":"j3","kind":"transcribe","meeting":"0d5e…","state":"running"}}
/// ```
public enum EarsEvent: Sendable, Hashable {
  /// A VAD state change on `source` at wall-clock instant `t` (telemetry).
  case vad(source: SourceID, state: VADState, t: Instant)
  /// A transcribed segment republished by `transcribe --follow` (telemetry).
  case segment(SegmentPublishParams)
  /// A session changed — always the full object (state).
  case session(Session)
  /// A source's runtime state changed (state).
  case source(id: SourceID, state: SourceRuntimeState)
  /// Pipeline job progress republished from `job.publish` (telemetry).
  case job(JobPublishParams)

  /// The wire discriminator this event is delivered under.
  public var kind: EventKind {
    switch self {
    case .vad: .vad
    case .segment: .segment
    case .session: .session
    case .source: .source
    case .job: .job
    }
  }

  /// The ``SourceID`` this event pertains to, for subscription source
  /// filtering. Only telemetry `vad` events are sourced; everything else
  /// always passes a source filter.
  public var filterSource: SourceID? {
    switch self {
    case .vad(let source, _, _): source
    default: nil
    }
  }
}

/// The notification envelope: `{"event": …, "params": {…}, "rev": …}`.
/// State events carry the monotonic state revision; telemetry events carry
/// none and never participate in gap detection.
public struct EventFrame: Sendable, Hashable {
  public var event: EarsEvent
  public var rev: Int?

  public init(event: EarsEvent, rev: Int? = nil) {
    self.event = event
    self.rev = rev
  }
}

extension EventFrame: Codable {
  private enum CodingKeys: String, CodingKey {
    case event, params, rev
  }

  private enum ParamsKeys: String, CodingKey {
    case source, state, t, id
    case speaker, start, end, text
    // `session` is the wire's `meeting` key until the wire rename (#47).
    case session = "meeting"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(EventKind.self, forKey: .event)
    rev = try container.decodeIfPresent(Int.self, forKey: .rev)
    switch kind {
    case .vad:
      let params = try container.nestedContainer(keyedBy: ParamsKeys.self, forKey: .params)
      event = .vad(
        source: try params.decode(SourceID.self, forKey: .source),
        state: try params.decode(VADState.self, forKey: .state),
        t: try params.decodeISO8601Instant(forKey: .t))
    case .segment:
      event = .segment(try container.decode(SegmentPublishParams.self, forKey: .params))
    case .session:
      let params = try container.nestedContainer(keyedBy: ParamsKeys.self, forKey: .params)
      event = .session(try params.decode(Session.self, forKey: .session))
    case .source:
      let params = try container.nestedContainer(keyedBy: ParamsKeys.self, forKey: .params)
      event = .source(
        id: try params.decode(SourceID.self, forKey: .id),
        state: try params.decode(SourceRuntimeState.self, forKey: .state))
    case .job:
      event = .job(try container.decode(JobPublishParams.self, forKey: .params))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(event.kind, forKey: .event)
    try container.encodeIfPresent(rev, forKey: .rev)
    switch event {
    case .vad(let source, let state, let t):
      var params = container.nestedContainer(keyedBy: ParamsKeys.self, forKey: .params)
      try params.encode(source, forKey: .source)
      try params.encode(state, forKey: .state)
      try params.encodeISO8601Instant(t, forKey: .t)
    case .segment(let segment):
      try container.encode(segment, forKey: .params)
    case .session(let session):
      var params = container.nestedContainer(keyedBy: ParamsKeys.self, forKey: .params)
      try params.encode(session, forKey: .session)
    case .source(let id, let state):
      var params = container.nestedContainer(keyedBy: ParamsKeys.self, forKey: .params)
      try params.encode(id, forKey: .id)
      try params.encode(state, forKey: .state)
    case .job(let job):
      try container.encode(job, forKey: .params)
    }
  }
}
