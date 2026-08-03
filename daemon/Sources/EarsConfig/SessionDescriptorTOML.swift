import EarsCore
import Foundation

/// Maps the ``Session`` entity to and from the `ConfigValue` tree that
/// mirrors `session.toml` **schema 3**
/// (`<data-root>/sessions/<uuid>/session.toml`) — the daemon-owned lifecycle
/// record of `docs/specs/control-protocol.md`. Schema 1 (the dead v1
/// identity-only `session.toml`) and schema 2 (the pre-rename
/// `meetings/<uuid>/meeting.toml`) are dead formats: they are ignored, never
/// read. `TOMLBridge` does the actual TOML text, this file only knows the
/// fields.
///
/// Optional scalars use the suite's "empty string ⇒ absent" sentinel
/// convention; `interval` and `attendee` are arrays of tables. `rev` is
/// deliberately **not** persisted — revisions are scoped to a daemon boot
/// (`hello`'s `boot_id`), so a persisted one would be a lie after restart.
public enum SessionDescriptorTOML {
  /// The `session.toml` schema version this build reads and writes.
  /// Bumped to 3 on the meeting→session rename so any stale schema-1 or
  /// schema-2 file on disk is unambiguously a dead format.
  public static let schemaVersion = 3

  /// Encodes a ``Session`` into the `ConfigValue` table `session.toml`
  /// serializes to.
  public static func encode(_ session: Session) -> ConfigValue {
    .table([
      "schema": .int(schemaVersion),
      "id": .string(session.id),
      "platform": .string(session.identity?.platform ?? ""),
      "external_id": .string(session.identity?.externalID ?? ""),
      "title": .string(session.title),
      "state": .string(session.state.rawValue),
      "started": .string(formatInstant(session.started)),
      "ended": .string(session.ended.map(formatInstant) ?? ""),
      "transcript_completed": .string(session.transcriptCompleted.map(formatInstant) ?? ""),
      "trigger": .string(session.trigger.rawValue),
      "sources": .array(session.sources.map { .string($0.rawValue) }),
      "interval": .array(
        session.intervals.map { interval in
          .table([
            "start": .string(formatInstant(interval.start)),
            "end": .string(interval.end.map(formatInstant) ?? ""),
          ])
        }),
      "attendee": .array(
        session.attendees.map { attendee in
          .table([
            "id": .string(attendee.id),
            "display_name": .string(attendee.displayName ?? ""),
            "joined": .string(attendee.joined.map(formatInstant) ?? ""),
            "left": .string(attendee.left.map(formatInstant) ?? ""),
            "source": .string(attendee.source?.rawValue ?? ""),
          ])
        }),
    ])
  }

  /// Decodes a ``Session`` from a `ConfigValue` table parsed from
  /// `session.toml`. Rejects any schema other than ``schemaVersion`` —
  /// tools reject a schema they don't understand rather than guessing
  /// (`docs/data-formats.md`).
  public static func decode(_ value: ConfigValue) throws(DescriptorTOMLError) -> Session {
    guard case .table(let table) = value else {
      throw .notATable
    }
    let fields = TOMLFieldReader(table: table)

    guard try fields.int("schema") == schemaVersion else {
      throw .invalidField("schema")
    }
    guard let state = SessionState(rawValue: try fields.string("state")) else {
      throw .invalidField("state")
    }
    guard let trigger = TriggerKind(rawValue: try fields.string("trigger")) else {
      throw .invalidField("trigger")
    }
    guard let started = parseInstant(try fields.string("started")) else {
      throw .invalidField("started")
    }
    let ended: Instant?
    if let endedRaw = fields.optionalString("ended") {
      guard let parsed = parseInstant(endedRaw) else { throw .invalidField("ended") }
      ended = parsed
    } else {
      ended = nil
    }

    let transcriptCompleted: Instant?
    if let raw = fields.optionalString("transcript_completed") {
      guard let parsed = parseInstant(raw) else { throw .invalidField("transcript_completed") }
      transcriptCompleted = parsed
    } else {
      transcriptCompleted = nil
    }

    let identity: SessionIdentity?
    if let platform = fields.optionalString("platform"),
      let externalID = fields.optionalString("external_id")
    {
      identity = SessionIdentity(platform: platform, externalID: externalID)
    } else {
      identity = nil
    }

    var sources: [SourceID] = []
    for element in try fields.array("sources") {
      guard case .string(let raw) = element else { throw .invalidField("sources") }
      sources.append(SourceID(raw))
    }

    var intervals: [SessionInterval] = []
    for element in try fields.array("interval") {
      guard case .table(let intervalTable) = element else { throw .invalidField("interval") }
      let intervalFields = TOMLFieldReader(table: intervalTable)
      guard let start = parseInstant(try intervalFields.string("start")) else {
        throw .invalidField("interval.start")
      }
      let end: Instant?
      if let endRaw = intervalFields.optionalString("end") {
        guard let parsed = parseInstant(endRaw) else { throw .invalidField("interval.end") }
        end = parsed
      } else {
        end = nil
      }
      intervals.append(SessionInterval(start: start, end: end))
    }

    var attendees: [SessionAttendee] = []
    for element in try fields.array("attendee") {
      guard case .table(let attendeeTable) = element else { throw .invalidField("attendee") }
      let attendeeFields = TOMLFieldReader(table: attendeeTable)
      attendees.append(
        SessionAttendee(
          id: try attendeeFields.string("id"),
          displayName: attendeeFields.optionalString("display_name"),
          joined: attendeeFields.optionalString("joined").flatMap(parseInstant),
          left: attendeeFields.optionalString("left").flatMap(parseInstant),
          source: attendeeFields.optionalString("source").map { SourceID($0) }))
    }

    return Session(
      id: try fields.string("id"),
      identity: identity,
      title: try fields.string("title"),
      state: state,
      started: started,
      ended: ended,
      intervals: intervals,
      attendees: attendees,
      sources: sources,
      trigger: trigger,
      transcriptCompleted: transcriptCompleted)
  }

  /// Standard colon-separated ISO-8601 UTC, whole seconds.
  private static func formatInstant(_ instant: Instant) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: instant.secondsSinceEpoch))
  }

  private static func parseInstant(_ string: String) -> Instant? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else { return nil }
    return Instant(secondsSinceEpoch: date.timeIntervalSince1970)
  }
}
