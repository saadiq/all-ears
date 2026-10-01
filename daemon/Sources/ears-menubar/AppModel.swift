import AppKit
import EarsCore
import EarsMenuKit
import Foundation
import Observation
import os

/// The menu's observable state and the loop that keeps it in step with the
/// daemon: socket frames → ``MenuStateReducer`` → ``MenuRenderer``. Verbs go
/// through ``SessionControls``, recent sessions through ``RecentsStore``, and
/// notifications through ``SessionNotifications``.
@MainActor @Observable final class AppModel {
  private(set) var state = MenuState()
  private(set) var content = MenuContent(
    icon: .idle, header: "Connecting to earsd…", verbs: [], pipeline: [])
  private(set) var uptime: DaemonUptime?
  /// The Daemon submenu's status line. Stored, not computed: it reads the
  /// clock, which nothing observes, so a computed line only refreshed when
  /// some other observed value changed — and an idle menu re-renders to an
  /// equal `content`, which `@Observable` does not announce.
  private(set) var daemonLine = DaemonUptime.line(daemon: nil, uptime: nil, now: AppClock.now())
  /// The last control call that failed, shown in the menu where the user who
  /// clicked is looking.
  private(set) var actionError: String?
  /// Starts `.authorized` so a launch does not flash a warning while the grant
  /// is still resolving.
  private(set) var notifications: NotificationAvailability = .authorized
  let recents: RecentsStore
  let dataRoot: String
  private let configError: String?
  private let connection: DaemonConnection?
  private let announcements = SessionNotifications()
  private let log = Logger(subsystem: "net.tomelliot.ears.menubar", category: "app")

  init(config: ClientConfig) {
    dataRoot = config.environment.dataRoot.path
    connection = DaemonConnection(socketPath: config.socketPath)
    recents = RecentsStore(loader: RecentsLoader(environment: config.environment))
    configError = nil
  }

  init(configError message: String) {
    dataRoot = ""
    connection = nil
    recents = RecentsStore(loader: nil)
    configError = message
    content = MenuContent(icon: .attention, header: "⚠ \(message)", verbs: [], pipeline: [])
  }

  func start() {
    guard let connection else { return }
    announcements.bootstrap(dataRoot: dataRoot, loader: recents.loader) { [weak self] in
      self?.notifications = $0
    }
    observeMenuTracking()
    Task { await connection.run() }
    Task { await pump(connection) }
  }

  func perform(_ verb: Verb) {
    guard let connection else { return }
    let controls = SessionControls(connection: connection)
    let call: @Sendable () async -> String?
    switch verb {
    case .startRecording: call = { await controls.startRecording() }
    case .pause(let session): call = { await controls.pause(session) }
    case .resume(let session): call = { await controls.resume(session) }
    case .end(let session): call = { await controls.end(session) }
    case .rename(let session, let currentTitle):
      guard let title = RenamePrompt.run(currentTitle: currentTitle) else { return }
      call = { await controls.rename(session, to: title) }
    }
    Task {
      if let message = await call() { report(message) } else { actionError = nil }
    }
  }

  func dismiss(jobID: String) {
    MenuStateReducer.dismissJob(&state, id: jobID)
    rerender()
  }

  /// `bounce()` yields no `.down`, so the state transition is this caller's:
  /// without it the menu keeps offering Pause/End over a socket that is gone.
  func restartDaemon() {
    guard let connection else { return }
    MenuStateReducer.resubscribing(&state)
    uptime = nil
    rerender()
    Task { [weak self] in
      if let error = await SystemActions.restartDaemon() { self?.report(error) }
      await connection.bounce()
    }
  }

  private func pump(_ connection: DaemonConnection) async {
    for await event in connection.events {
      switch event {
      case .ready(let daemon, let snapshot):
        MenuStateReducer.connected(&state, daemon: daemon, snapshot: snapshot)
        actionError = nil
        anchorUptime(connection)
        recents.refresh()
      case .event(let frame):
        let before = state
        switch MenuStateReducer.apply(&state, frame) {
        case .gap:
          // Only the first gap bounces: frames queued behind it are from the
          // same dead stream and reduce to `.gap` too.
          if state.connection == .connected {
            MenuStateReducer.resubscribing(&state)
            await connection.bounce()
          }
        case .applied:
          announcements.announce(frame, before: before)
          if RecentsRefreshPolicy.shouldRefresh(for: frame) { recents.refresh() }
        case .ignoredStale:
          break
        }
      case .down:
        // Before reducing: the warning is edge-triggered off the state it drops from.
        announcements.warnAtRisk(state: state)
        MenuStateReducer.disconnected(&state)
        uptime = nil
      }
      rerender()
    }
  }

  /// Re-anchors uptime against the process now on the socket. A failed
  /// `status` leaves no anchor rather than the previous process's.
  private func anchorUptime(_ connection: DaemonConnection) {
    Task { [weak self] in
      let status = await connection.status()
      self?.uptime = status.map {
        DaemonUptime(reported: Double($0.uptimeSeconds), anchor: AppClock.now())
      }
      self?.rerender()
    }
  }

  private func report(_ message: String) {
    log.error("control call failed: \(message, privacy: .public)")
    actionError = message
  }

  private func rerender() {
    // `state.daemon` is kept across a drop for display, so an unreachable
    // daemon must be named as such here rather than by its last version.
    daemonLine = DaemonUptime.line(
      daemon: state.connection == .unreachable ? nil : state.daemon, uptime: uptime,
      now: AppClock.now())
    // The config-error model's content *is* the error; rendering the empty
    // state over it would replace it with a wait that never ends.
    guard configError == nil else { return }
    content = MenuRenderer.render(state, now: AppClock.now())
  }

  private func menuWillOpen() {
    rerender()
    recents.refresh()
    announcements.refreshAvailability { [weak self] in self?.notifications = $0 }
  }

  /// The menu-style `MenuBarExtra` gives its content no per-open hook;
  /// AppKit still posts `didBeginTracking` for the status item's menu, and
  /// this `LSUIElement` app has exactly one menu.
  private func observeMenuTracking() {
    Task { [weak self] in
      let opens = NotificationCenter.default.notifications(
        named: NSMenu.didBeginTrackingNotification)
      for await _ in opens {
        guard let self else { return }
        self.menuWillOpen()
      }
    }
  }
}
