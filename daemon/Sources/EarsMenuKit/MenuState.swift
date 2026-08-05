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

extension MenuState {
  mutating func upsertSession(_ session: Session) {
    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[index] = session
    } else {
      sessions.append(session)
    }
  }

  mutating func updateSource(id: SourceID, to newState: SourceRuntimeState) {
    if let index = sources.firstIndex(where: { $0.id == id }) {
      sources[index].state = newState
    } else {
      sources.append(SourceStatus(id: id, state: newState, codec: ""))
    }
  }
}
