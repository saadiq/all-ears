import EarsCore
import EarsMenuKit

/// Daemon connection health and lifecycle: catching a freshly (re)connected
/// client up on status, the Daemon submenu's uptime line, renaming a
/// session, and the Restart Daemon action. Split out of `AppModel.swift` to
/// keep that file under the project's line-count limit; these members reach
/// into state and helpers declared there (`state`, `uptime`, `connection`,
/// `rerender`, `report`, `send`, `offerDetectedMeetings`, `now`), each left
/// non-`private` specifically so this extension can reach them.
extension AppModel {
  /// Re-anchors the Daemon submenu's uptime against the process now on the
  /// other end of the socket, and replays `status`'s `meeting_activity` list
  /// into `state` — the catch-up a freshly (re)connected client needs because
  /// `connected()` cleared it and telemetry only carries the next edge, not
  /// a snapshot.
  ///
  /// Clears the anchor when the `status` round-trip fails instead of leaving
  /// the previous one: it belongs to a *different* process, so keeping it made
  /// `daemonLine` report the dead daemon's uptime — "up 2d 6h" for something
  /// that started thirty seconds ago, telling a user who just clicked Restart
  /// Daemon that nothing happened. No anchor renders the bare version line,
  /// which claims nothing.
  func catchUpStatus(_ connection: DaemonConnection) {
    // Captured before the `await` below: a live `.meetingActivity` edge that
    // lands and bumps this while `status` is in flight makes the mark stale,
    // so the reducer discards the catch-up instead of clobbering the edge.
    let mark = state.meetingActivityEdits
    Task { [weak self] in
      let status = await connection.status()
      guard let self else { return }
      self.uptime = status.map {
        DaemonUptime(reported: Double($0.uptimeSeconds), anchor: Self.now())
      }
      if let status {
        MenuStateReducer.catchUpMeetingActivity(
          &self.state, status.meetingActivity, ifEditsEqual: mark)
      }
      self.rerender()
      self.offerDetectedMeetings()
    }
  }

  func promptRename(session: String, currentTitle: String) {
    guard let title = RenamePrompt.run(currentTitle: currentTitle), let connection else { return }
    send(.sessionRename(SessionRenameParams(session: session, title: title)), connection)
  }

  var daemonLine: String {
    DaemonUptime.line(daemon: state.daemon, uptime: uptime, now: Self.now())
  }

  func restartDaemon() {
    guard let connection else { return }
    // `bounce()` is deliberately silent — it yields no `.down` — so the state
    // transition is this caller's to make. Without it the menu keeps
    // advertising "● Recording" and offering Pause/End over a socket that no
    // longer exists, and clicking one answers "⚠ not connected to earsd".
    MenuStateReducer.resubscribing(&state)
    uptime = nil
    rerender()
    Task { [weak self] in
      // A failed kickstart is not a no-op from the user's side: the bounce
      // below still drops the menu to "⚠ Daemon not running", so a discarded
      // error reads as this button having broken something.
      if let error = await SystemActions.restartDaemon() {
        self?.report(error)
      }
      await connection.bounce()
    }
  }
}
