import EarsCore

public enum ReduceOutcome: Sendable, Hashable {
  case applied
  case ignoredStale
  case gap
}

public enum MenuStateReducer {
  /// Job telemetry is transient and not part of the snapshot, so it can never be
  /// replayed: any `done` event missed during a disconnect/reconnect bounce would
  /// otherwise leave a stale "in progress" line (and the busy icon) forever. Every
  /// (re)subscribe therefore drops all non-failed job lines, boot change or not;
  /// failed lines persist until the user dismisses them. Discarding unconditionally
  /// subsumes the spec's `boot_id` check — a restarted daemon is one of the cases it
  /// already covers — so no caller needs to track the boot id.
  public static func connected(
    _ state: inout MenuState, daemon: String, snapshot: SnapshotData
  ) {
    state.connection = .connected
    state.daemon = daemon
    state.sessions = snapshot.sessions
    state.sources = snapshot.sources
    state.lastRev = snapshot.rev
    state.jobs.removeAll { $0.state != .failed }
    // Not part of the snapshot: a reconnect's status catch-up refills it, so
    // starting from empty avoids showing a meeting as active off a boot the
    // daemon may not even have made it through.
    state.meetingActivity = []
  }

  public static func disconnected(_ state: inout MenuState) {
    state.connection = .unreachable
  }

  /// A rev gap: this client's mirror of the daemon's state is no longer
  /// trustworthy, so the socket is bounced and resubscribed. `.connecting`
  /// rather than `.unreachable` — the daemon is very likely alive; what is
  /// gone is *our* sync — and either way the menu must stop offering Pause/End
  /// for a session it can no longer control over a socket that no longer
  /// exists. Clearing `lastRev` also makes every already-queued stale frame
  /// reduce to `.gap` again, which the caller uses to bounce exactly once.
  public static func resubscribing(_ state: inout MenuState) {
    state.connection = .connecting
    state.lastRev = nil
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
    case .meetingActivity(let status):
      state.upsertMeetingActivity(status)
      return .applied
    case .vad, .segment:
      return .applied
    }
  }

  public static func dismissJob(_ state: inout MenuState, id: String) {
    state.jobs.removeAll { $0.job == id }
  }

  /// `status`'s `meeting_activity` list, applied wholesale — the catch-up a
  /// freshly connected client does instead of waiting for the next edge.
  ///
  /// `mark` is the caller's `state.meetingActivityEdits` from just before it
  /// asked the daemon for `status`. If a live `.meetingActivity` edge landed
  /// (and bumped the counter) while that request was in flight, `list` is a
  /// stale snapshot of a state the edge has already moved past — replacing
  /// wholesale would silently revert it, and edges are one-shot, so nothing
  /// would ever correct the mistake. Discarding here is correct: the live
  /// feed is newer than the catch-up.
  public static func catchUpMeetingActivity(
    _ state: inout MenuState, _ list: [MeetingActivityStatus], ifEditsEqual mark: Int
  ) {
    guard state.meetingActivityEdits == mark else { return }
    state.meetingActivity = list
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
