/// The daemon-owned session lifecycle entity of control protocol v2
/// (`docs/specs/control-protocol.md`'s "Meeting" — daemon vocabulary says
/// "session"; the wire keeps the `meeting.*` spelling until #47): owns the
/// transcription marks (``intervals``), the attendee roster, and the title.
/// Persisted as `sessions/<uuid>/session.toml` (schema 3, see
/// `EarsConfig.SessionDescriptorTOML`) plus an append-only `events.jsonl`
/// timeline; its `Codable` conformance is the v2 *wire* shape (snake_case,
/// ISO-8601 instants) carried in `meeting.*` results and `meeting` events.
///
/// Intervals are marks over the recording, never capture control: pausing a
/// session closes the open interval, resuming opens a new one, and the
/// capture engines/ingest streams are untouched throughout.
public struct Session: Sendable, Hashable {
  /// The daemon-assigned session UUID — the one internal id used everywhere
  /// (filenames, CLI output).
  public var id: String
  /// The platform-specific external identity `session.start` is idempotent
  /// on; `nil` for manual sessions.
  public var identity: SessionIdentity?
  /// Renameable display title; defaults from ``identity`` (or the id) when
  /// the client never named one.
  public var title: String
  public var state: SessionState
  public var started: Instant
  /// Set once on `session.end`; `nil` while active/paused.
  public var ended: Instant?
  /// Transcription marks over the recording. A `nil` interval end means
  /// "currently marked" (the session is active).
  public var intervals: [SessionInterval]
  /// The roster, upserted by whoever knows it (the extension's DOM layer
  /// today).
  public var attendees: [SessionAttendee]
  /// Every source involved in this session — what transcription reads, and
  /// (for `browser:*` entries) what the orphan grace timer watches.
  public var sources: [SourceID]
  /// Provenance: what started this session.
  public var trigger: TriggerKind
  /// When this session's transcript last completed **successfully** — the
  /// durable marker retention keys off (`docs/specs/capture-daemon.md`'s
  /// "Retention"). `nil` until a transcript run succeeds; once set, the
  /// session's audio is evicted `evict_after_transcript_seconds` later. A
  /// session whose transcript never succeeds keeps this `nil` and its audio is
  /// instead retained until `max_audio_age_seconds` after it ended.
  public var transcriptCompleted: Instant?
  /// The last state revision that touched this session. Boot-scoped (see
  /// `hello`'s `boot_id`), so never persisted to `session.toml`.
  public var rev: Int

  public init(
    id: String,
    identity: SessionIdentity? = nil,
    title: String,
    state: SessionState,
    started: Instant,
    ended: Instant? = nil,
    intervals: [SessionInterval] = [],
    attendees: [SessionAttendee] = [],
    sources: [SourceID] = [],
    trigger: TriggerKind = .manual,
    transcriptCompleted: Instant? = nil,
    rev: Int = 0
  ) {
    self.id = id
    self.identity = identity
    self.title = title
    self.state = state
    self.started = started
    self.ended = ended
    self.intervals = intervals
    self.attendees = attendees
    self.sources = sources
    self.trigger = trigger
    self.transcriptCompleted = transcriptCompleted
    self.rev = rev
  }

  /// Whether any of this session's sources is a `browser:*` source — the
  /// discriminator for the orphaned-session policy (browser sessions
  /// auto-end after the ingest-close grace; manual sessions never do).
  public var isBrowserSession: Bool {
    sources.contains { $0.sourceClass == .browser }
  }
}

/// A session's lifecycle state.
public enum SessionState: String, Sendable, Hashable, Codable, CaseIterable {
  case active
  case paused
  case ended
}

/// The platform-specific external identity `session.start` is idempotent on.
public struct SessionIdentity: Sendable, Hashable, Codable {
  /// e.g. `meet`.
  public var platform: String
  /// The platform's own meeting identifier (the platform concept keeps the
  /// name "meeting"), e.g. Meet's `<space>` segment.
  public var externalID: String

  public init(platform: String, externalID: String) {
    self.platform = platform
    self.externalID = externalID
  }

  private enum CodingKeys: String, CodingKey {
    case platform
    case externalID = "external_id"
  }
}

/// One transcription mark over the recording; `end == nil` means the span
/// is currently marked.
public struct SessionInterval: Sendable, Hashable {
  public var start: Instant
  public var end: Instant?

  public init(start: Instant, end: Instant? = nil) {
    self.start = start
    self.end = end
  }
}

/// One roster entry, with join/leave times and an optional mapping to the
/// attendee's per-participant audio source (which downstream feeds the
/// transcript's speaker-name map).
public struct SessionAttendee: Sendable, Hashable {
  /// The platform's participant id, e.g. `spaces/x/devices/y`.
  public var id: String
  public var displayName: String?
  public var joined: Instant?
  public var left: Instant?
  /// The attendee's per-participant audio source, when known.
  public var source: SourceID?

  public init(
    id: String,
    displayName: String? = nil,
    joined: Instant? = nil,
    left: Instant? = nil,
    source: SourceID? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.joined = joined
    self.left = left
    self.source = source
  }
}

// MARK: - Wire coding (v2 JSON: snake_case keys, ISO-8601 instants)

extension Session: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, identity, title, state, started, ended, intervals, attendees, sources, trigger, rev
    case transcriptCompleted = "transcript_completed"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    identity = try container.decodeIfPresent(SessionIdentity.self, forKey: .identity)
    title = try container.decode(String.self, forKey: .title)
    state = try container.decode(SessionState.self, forKey: .state)
    started = try container.decodeISO8601Instant(forKey: .started)
    ended = try container.decodeISO8601InstantIfPresent(forKey: .ended)
    intervals = try container.decodeIfPresent([SessionInterval].self, forKey: .intervals) ?? []
    attendees = try container.decodeIfPresent([SessionAttendee].self, forKey: .attendees) ?? []
    sources = try container.decodeIfPresent([SourceID].self, forKey: .sources) ?? []
    trigger = try container.decode(TriggerKind.self, forKey: .trigger)
    transcriptCompleted = try container.decodeISO8601InstantIfPresent(forKey: .transcriptCompleted)
    rev = try container.decodeIfPresent(Int.self, forKey: .rev) ?? 0
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(identity, forKey: .identity)
    try container.encode(title, forKey: .title)
    try container.encode(state, forKey: .state)
    try container.encodeISO8601Instant(started, forKey: .started)
    try container.encodeISO8601InstantIfPresent(ended, forKey: .ended)
    try container.encode(intervals, forKey: .intervals)
    try container.encode(attendees, forKey: .attendees)
    try container.encode(sources, forKey: .sources)
    try container.encode(trigger, forKey: .trigger)
    try container.encodeISO8601InstantIfPresent(transcriptCompleted, forKey: .transcriptCompleted)
    try container.encode(rev, forKey: .rev)
  }
}

extension SessionInterval: Codable {
  private enum CodingKeys: String, CodingKey {
    case start, end
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    start = try container.decodeISO8601Instant(forKey: .start)
    end = try container.decodeISO8601InstantIfPresent(forKey: .end)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeISO8601Instant(start, forKey: .start)
    // Always written (as `null` while open) so "currently marked" is
    // explicit in the spec's literal example shape.
    switch end {
    case .some(let end): try container.encodeISO8601Instant(end, forKey: .end)
    case .none: try container.encodeNil(forKey: .end)
    }
  }
}

extension SessionAttendee: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, joined, left, source
    case displayName = "display_name"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    joined = try container.decodeISO8601InstantIfPresent(forKey: .joined)
    left = try container.decodeISO8601InstantIfPresent(forKey: .left)
    source = try container.decodeIfPresent(SourceID.self, forKey: .source)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(displayName, forKey: .displayName)
    try container.encodeISO8601InstantIfPresent(joined, forKey: .joined)
    try container.encodeISO8601InstantIfPresent(left, forKey: .left)
    try container.encodeIfPresent(source, forKey: .source)
  }
}
