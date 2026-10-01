import EarsCore
import Foundation

/// One Recent Sessions row: an ended session plus what its scan found on
/// disk. `nil`/empty means not there, and the menu disables the verb rather
/// than offering a path that opens nothing.
public struct RecentSessionItem: Identifiable, Sendable, Equatable {
  public var session: Session
  /// The raw transcript in the data store — an intermediate, offered last.
  public var transcript: URL?
  /// The published, cleaned transcript: the file you actually read.
  public var clean: URL?
  public var summaries: [URL]
  public var outcome: PipelineOutcome
  public var id: String { session.id }

  public init(session: Session, artifacts: SessionArtifacts, outcome: PipelineOutcome) {
    self.session = session
    transcript =
      artifacts.transcriptExists ? artifacts.transcriptPath.map { URL(fileURLWithPath: $0) } : nil
    clean = artifacts.cleanupExists ? artifacts.cleanupPath.map { URL(fileURLWithPath: $0) } : nil
    summaries = artifacts.summaryPaths.map { URL(fileURLWithPath: $0) }
    self.outcome = outcome
  }
}

public enum RecentSessions {
  /// Ended sessions, most recently *ended* first — the order `ears status`'s
  /// recent tail uses. A record with no end instant sorts on its start.
  public static func select(from sessions: [Session], limit: Int = 7) -> [Session] {
    Array(
      sessions.filter { $0.state == .ended }
        .sorted { ($0.ended ?? $0.started) > ($1.ended ?? $1.started) }
        .prefix(limit))
  }
}
