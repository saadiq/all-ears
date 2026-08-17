import EarsConfig
import EarsCore
import Foundation

/// Reads and writes a session's `session.toml` (schema 3), per the
/// `sessions/<session-id>/session.toml` layout — thin file I/O only: the
/// field mapping is `SessionDescriptorTOML` (`EarsConfig`), the serialization
/// is `printableConfig(_:)`/`readConfigFileLayer(at:)`. Written atomically on
/// every mutation so a crash never leaves a torn descriptor.
public enum SessionStore {
  /// Writes `session` to `<data-root>/sessions/<session-id>/session.toml`,
  /// creating the session directory if it doesn't exist yet.
  public static func write(_ session: Session, dataRoot: URL) throws {
    let url = DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: session.id)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let text = printableConfig(SessionDescriptorTOML.encode(session))
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Reads `<data-root>/sessions/<session-id>/session.toml`.
  ///
  /// - Throws: ``DataStoreError/sessionNotFound(_:)`` if the file doesn't
  ///   exist; ``DescriptorTOMLError`` if it exists but doesn't parse into a
  ///   valid ``Session`` (an unknown schema included).
  public static func read(sessionID: String, dataRoot: URL) throws -> Session {
    let url = DataStoreLayout.sessionTomlFile(dataRoot: dataRoot, sessionID: sessionID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw DataStoreError.sessionNotFound(sessionID)
    }
    let value = try readConfigFileLayer(at: url.path)
    return try SessionDescriptorTOML.decode(value)
  }

  /// Reads every parseable `sessions/*/session.toml` under `dataRoot` — the
  /// startup scan `SessionRegistry` rebuilds its state from, and what
  /// `ears session list --all` reads daemon-free. A missing `sessions/`
  /// directory is an empty list, and an unparseable descriptor is skipped
  /// and reported via `onSkip` rather than failing the whole scan.
  public static func readAll(
    dataRoot: URL, onSkip: (String, Error) -> Void = { _, _ in }
  ) -> [Session] {
    let directory = DataStoreLayout.sessionsDirectory(dataRoot: dataRoot)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    var sessions: [Session] = []
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let sessionID = entry.lastPathComponent
      do {
        sessions.append(try read(sessionID: sessionID, dataRoot: dataRoot))
      } catch DataStoreError.sessionNotFound {
        continue  // a stray non-session entry under sessions/ — not an error
      } catch {
        onSkip(sessionID, error)
      }
    }
    return sessions
  }
}

/// Appends domain events to a session's `sessions/<uuid>/events.jsonl` — the
/// durable per-session timeline (who was present during minutes 10–20, when
/// pauses happened, what the session used to be called). Written for disk
/// consumers (`summarize`, humans, `jq`), **not** used for protocol sync;
/// mirrors the `index.jsonl` append-only idiom.
public enum SessionEventLog {
  /// One `events.jsonl` line. `event` is one of `started`,
  /// `interval_opened`, `interval_closed`, `attendee_joined`,
  /// `attendee_left`, `renamed`, `capture_failed`, `ended`; the optional
  /// fields carry the event's own detail.
  public struct Entry: Sendable, Hashable, Codable {
    public var t: String
    public var event: String
    /// `attendee_joined`/`attendee_left`: the attendee id.
    public var attendee: String?
    /// `renamed`: the new title.
    public var title: String?
    /// `capture_failed`: the source whose capture died mid-call.
    public var source: String?
    /// `ended`: `"client"` for an explicit `session.end`, `"ingest-idle"`
    /// for the browser orphan grace timer, `"app-idle"` for its app-detected
    /// mirror (app-audio activity went quiet past grace). `capture_failed`:
    /// the capture client's stated cause.
    public var reason: String?

    public init(
      t: String, event: String, attendee: String? = nil, title: String? = nil,
      source: String? = nil, reason: String? = nil
    ) {
      self.t = t
      self.event = event
      self.attendee = attendee
      self.title = title
      self.source = source
      self.reason = reason
    }
  }

  /// `<data-root>/sessions/<session-id>/events.jsonl`.
  public static func fileURL(dataRoot: URL, sessionID: String) -> URL {
    DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: sessionID)
      .appendingPathComponent("events.jsonl")
  }

  /// Appends one entry (creating the file and directory as needed). Failures
  /// throw — callers decide whether the timeline is best-effort.
  public static func append(
    _ entry: Entry, dataRoot: URL, sessionID: String
  ) throws {
    let url = fileURL(dataRoot: dataRoot, sessionID: sessionID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var line = try encoder.encode(entry)
    line.append(0x0A)
    if let handle = FileHandle(forWritingAtPath: url.path) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } else {
      try line.write(to: url)
    }
  }

  /// Reads every parseable entry, in file order — for tests and disk
  /// consumers; unparseable lines are skipped.
  public static func readAll(dataRoot: URL, sessionID: String) -> [Entry] {
    let url = fileURL(dataRoot: dataRoot, sessionID: sessionID)
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { line in
      try? decoder.decode(Entry.self, from: Data(line.utf8))
    }
  }
}

/// Appends the browser's attribution flight-recorder events to a session's
/// `sessions/<uuid>/attribution.jsonl`, beside `events.jsonl` — same
/// append-only JSONL discipline, and like `events.jsonl` it survives audio
/// retention (only `sources/` is ever deleted).
///
/// Unlike ``SessionEventLog`` the daemon does not own the vocabulary: each
/// line arrives pre-encoded from the extension (`browser/lib/attribution-log.ts`,
/// schema-versioned per line) and is written **verbatim**, so what lands on
/// disk is byte-for-byte what the browser recorded. The only gate is framing:
/// a line must parse as a single JSON object with no embedded newline, or the
/// JSONL file itself would be corrupted for every later reader.
public enum SessionAttributionLog {
  /// `<data-root>/sessions/<session-id>/attribution.jsonl`.
  public static func fileURL(dataRoot: URL, sessionID: String) -> URL {
    DataStoreLayout.sessionDirectory(dataRoot: dataRoot, sessionID: sessionID)
      .appendingPathComponent("attribution.jsonl")
  }

  /// Appends `lines` (creating the file and directory as needed), skipping
  /// any that would break the JSONL framing. Returns how many were written.
  /// Failures throw — callers decide whether the log is best-effort.
  @discardableResult
  public static func append(
    lines: [String], dataRoot: URL, sessionID: String
  ) throws -> Int {
    let valid = lines.filter(isValidLine)
    guard !valid.isEmpty else { return 0 }
    let url = fileURL(dataRoot: dataRoot, sessionID: sessionID)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload = Data((valid.joined(separator: "\n") + "\n").utf8)
    if let handle = FileHandle(forWritingAtPath: url.path) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: payload)
    } else {
      try payload.write(to: url)
    }
    return valid.count
  }

  /// Every line, in file order, verbatim — for tests and offline replay.
  public static func readAllLines(dataRoot: URL, sessionID: String) -> [String] {
    let url = fileURL(dataRoot: dataRoot, sessionID: sessionID)
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  /// One JSON object, no embedded newline — the framing contract above.
  private static func isValidLine(_ line: String) -> Bool {
    guard !line.contains("\n"), !line.contains("\r") else { return false }
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
      return false
    }
    return object is [String: Any]
  }
}
