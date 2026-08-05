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

  public static func apply(_ state: inout MenuState, _ frame: EventFrame) -> ReduceOutcome {
    switch frame.event {
    case .session(let session):
      return applyState(&state, rev: frame.rev) { $0.upsertSession(session) }
    case .source(let id, let runtimeState):
      return applyState(&state, rev: frame.rev) { $0.updateSource(id: id, to: runtimeState) }
    case .job(let params):
      upsertJob(&state, params)
      return .applied
    case .vad, .segment:
      return .applied
    }
  }

  public static func dismissJob(_ state: inout MenuState, id: String) {
    state.jobs.removeAll { $0.job == id }
  }

  private static func applyState(
    _ state: inout MenuState, rev: Int?, mutate: (inout MenuState) -> Void
  ) -> ReduceOutcome {
    guard let rev, let lastRev = state.lastRev else { return .gap }
    if rev <= lastRev { return .ignoredStale }
    guard rev == lastRev + 1 else { return .gap }
    mutate(&state)
    state.lastRev = rev
    return .applied
  }

  private static func upsertJob(_ state: inout MenuState, _ params: JobPublishParams) {
    if params.state == .done {
      state.jobs.removeAll { $0.job == params.job }
      return
    }
    if let index = state.jobs.firstIndex(where: { $0.job == params.job }) {
      state.jobs[index] = params
    } else {
      state.jobs.append(params)
    }
  }
}
