import EarsCore

public enum ReduceOutcome: Sendable, Hashable {
  case applied
  case ignoredStale
  case gap
}

public enum MenuStateReducer {
  public static func connected(
    _ state: inout MenuState, daemon: String, bootChanged: Bool, snapshot: SnapshotData
  ) {
    state.connection = .connected
    state.daemon = daemon
    state.sessions = snapshot.sessions
    state.sources = snapshot.sources
    state.lastRev = snapshot.rev
    if bootChanged {
      state.jobs.removeAll { $0.state != .failed }
    }
  }

  public static func disconnected(_ state: inout MenuState) {
    state.connection = .unreachable
  }
}
