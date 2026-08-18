import EarsCore
import Foundation

/// Renders v2 results for `ears`'s stdout -- either `--json` (the raw result
/// payload, for scripting) or a short human-readable summary per payload
/// type. Wire errors are handled by ``ControlClientRuntime/send``'s caller
/// (they arrive as thrown `WireError`s).
enum OutputFormatting {
  private static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  /// Prints a successful result and returns exit code 0.
  static func emit<Payload: Codable & Sendable & Hashable>(
    _ payload: Payload, json: Bool, humanSuccess: (Payload) -> String
  ) -> Int32 {
    if json {
      printJSON(payload)
    } else {
      print(humanSuccess(payload))
    }
    return 0
  }

  private static func printJSON(_ payload: some Encodable) {
    guard let data = try? jsonEncoder.encode(payload),
      let string = String(data: data, encoding: .utf8)
    else {
      print("{}")
      return
    }
    print(string)
  }

  // MARK: - Per-payload human renderers

  static func humanSourcesList(_ data: SourcesListData) -> String {
    data.sources.isEmpty
      ? "(no sources)" : data.sources.map(humanSourceLine).joined(separator: "\n")
  }

  private static func humanSourceLine(_ source: SourceStatus) -> String {
    "\(source.id.rawValue)\t\(source.state.rawValue)\t\(source.codec)\tbytes_used=\(source.bytesUsed)"
  }

  static func humanEmpty(_: EmptyData) -> String {
    "ok"
  }

  static func humanSession(_ session: Session) -> String {
    humanSessionLine(session)
  }

  static func humanSessions(_ sessions: [Session]) -> String {
    sessions.isEmpty
      ? "(no sessions)" : sessions.map(humanSessionLine).joined(separator: "\n")
  }

  static func humanSessionLine(_ session: Session) -> String {
    var parts = [
      "session",
      session.id,
      session.state.rawValue,
      "\"\(session.title)\"",
    ]
    if let identity = session.identity {
      parts.append("\(identity.platform):\(identity.externalID)")
    }
    parts.append("intervals=\(session.intervals.count)")
    if !session.attendees.isEmpty {
      parts.append("attendees=\(session.attendees.count)")
    }
    // Age surfacing (#24): the start instant, and the last interval boundary as
    // last-activity, so a weeks-old still-`active` session is visually anomalous.
    parts.append("started=\(ISO8601InstantCodec.format(session.started))")
    parts.append("last_activity=\(ISO8601InstantCodec.format(lastActivity(session)))")
    return parts.joined(separator: "\t")
  }

  /// The most recent interval boundary (or `started` if none) — mirrors the
  /// daemon's own last-activity notion for the CLI's session rows.
  private static func lastActivity(_ session: Session) -> Instant {
    var latest = session.started
    for interval in session.intervals {
      latest = max(latest, interval.start)
      if let end = interval.end {
        latest = max(latest, end)
      }
    }
    return latest
  }

  static func humanEvent(_ frame: EventFrame) -> String {
    let revSuffix = frame.rev.map { " rev=\($0)" } ?? ""
    switch frame.event {
    case .vad(let source, let state, let t):
      return "[\(t)] vad \(source.rawValue) \(state.rawValue)"
    case .segment(let segment):
      return
        "[\(segment.session)] \(segment.speaker) (\(segment.start)-\(segment.end)): \(segment.text)"
    case .session(let session):
      return "[session] \(humanSessionLine(session))\(revSuffix)"
    case .source(let id, let state):
      return "[source] \(id.rawValue) \(state.rawValue)\(revSuffix)"
    case .job(let job):
      let target = job.session.map { " session=\($0)" } ?? ""
      return "[job] \(job.job) \(job.kind)\(target) \(job.state.rawValue)"
    }
  }
}
