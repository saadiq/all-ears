import EarsCore

public enum ConnectionPhase: Sendable, Hashable {
  case connecting
  case connected
  case unreachable
}

/// The single immutable value everything renders from. Sessions/sources mirror
/// the daemon's revision-synced state; jobs are telemetry accumulated locally.
public struct MenuState: Sendable, Hashable {
  public var connection: ConnectionPhase
  public var daemon: String?
  public var sessions: [Session]
  public var sources: [SourceStatus]
  public var jobs: [JobPublishParams]
  public var lastRev: Int?

  public init() {
    connection = .connecting
    daemon = nil
    sessions = []
    sources = []
    jobs = []
    lastRev = nil
  }

  public var activeSession: Session? {
    sessions.first { $0.state == .active || $0.state == .paused }
  }
  public var runningJobs: [JobPublishParams] {
    jobs.filter { $0.state == .started || $0.state == .running }
  }
  public var failedJobs: [JobPublishParams] {
    jobs.filter { $0.state == .failed }
  }
}
