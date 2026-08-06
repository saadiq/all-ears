import EarsCore

public struct SessionArtifactKey: Sendable, Hashable {
  public var day: String  // "2026-07-17"
  public var filePrefix: String  // "10-30-00_<session-id>"

  public init(day: String, filePrefix: String) {
    self.day = day
    self.filePrefix = filePrefix
  }
}

public struct SessionArtifacts: Sendable, Hashable {
  public var transcript: String?
  public var clean: String?
  public var summaries: [String]

  public init(transcript: String? = nil, clean: String? = nil, summaries: [String] = []) {
    self.transcript = transcript
    self.clean = clean
    self.summaries = summaries
  }
}

public enum SessionArtifactLocator {
  /// Mirrors transcribe's OutputPathResolution for session runs: the timestamp
  /// comes from the first non-empty interval's start and the slug is the
  /// session id. Keep in lockstep with Sources/transcribe/OutputPathResolution.swift.
  public static func key(for session: Session) -> SessionArtifactKey? {
    guard let start = firstNonEmptyIntervalStart(session) else { return nil }
    let timestamp = FilenameTimestampCodec.string(for: start)  // "2026-07-17T10-30-00Z"
    let parts = timestamp.split(separator: "T", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    return SessionArtifactKey(
      day: String(parts[0]),
      filePrefix: "\(String(parts[1].dropLast()))_\(session.id)")
  }

  public static func classify(filenames: [String], key: SessionArtifactKey) -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    for name in filenames.sorted() where name.hasPrefix(key.filePrefix) {
      if name == "\(key.filePrefix).transcript.md" {
        artifacts.transcript = name
      } else if name == "\(key.filePrefix).clean.md" {
        artifacts.clean = name
      } else if name.hasSuffix(".summary.md") {
        artifacts.summaries.append(name)
      }
    }
    return artifacts
  }

  private static func firstNonEmptyIntervalStart(_ session: Session) -> Instant? {
    for interval in session.intervals {
      guard let end = interval.end ?? session.ended else { continue }
      if interval.start < end { return interval.start }
    }
    return nil
  }
}

public enum RecentSessions {
  public static func select(from sessions: [Session], limit: Int = 7) -> [Session] {
    Array(
      sessions.filter { $0.state == .ended }
        .sorted { $0.started > $1.started }
        .prefix(limit))
  }
}
