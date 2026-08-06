import AppKit
import EarsCore
import EarsDataStore
import EarsMenuKit
import Foundation
import Observation
import os

@MainActor @Observable final class AppModel {
  private(set) var state = MenuState()
  private(set) var content = MenuContent(
    icon: .idle, header: "Connecting to earsd…", verbs: [], pipeline: [])
  private(set) var recents: [RecentSessionItem] = []
  private(set) var uptime: DaemonUptime?
  /// The last control call that failed, kept for the menu to show. A verb that
  /// silently does nothing is the worst outcome here: the user walks away
  /// believing a recording stopped when it did not.
  private(set) var actionError: String?
  /// Whether posted notifications actually reach the user. Starts `.authorized`
  /// so a launch does not flash a warning while the grant is still resolving.
  private(set) var notifications: NotificationAvailability = .authorized
  let configError: String?
  let dataRoot: String
  let outputRoot: String

  private let connection: DaemonConnection?
  private let recentsProvider: RecentSessionsProvider
  private let announcements = SessionNotifications()
  /// What a manually started session declares. Re-read from disk on every
  /// menu open rather than frozen at launch: this app is a login item, so
  /// "frozen at launch" means "frozen until reboot", and a user who edits
  /// `[[earsd.source]]` and uses this app's own Restart Daemon would keep
  /// starting sessions against the old list — recording nothing but mic while
  /// the menu reports "● Recording" — with no way to tell.
  private var sources: [SourceID]
  private var onEndStages: [String]
  /// Re-resolves the config layers. Injected so the reload path is a seam
  /// rather than a hard call into the filesystem.
  private let reloadConfig: @Sendable () -> ClientConfig?
  private let log = Logger(subsystem: "net.tomelliot.ears.menubar", category: "app")

  init(
    config: ClientConfig,
    reloadConfig: @escaping @Sendable () -> ClientConfig? = { try? ClientConfig.resolve().get() }
  ) {
    configError = nil
    dataRoot = config.dataRoot
    outputRoot = config.outputRoot
    sources = config.sources
    onEndStages = config.onEndStages
    self.reloadConfig = reloadConfig
    connection = DaemonConnection(socketPath: config.socketPath)
    recentsProvider = RecentSessionsProvider(
      dataRoot: config.dataRoot, outputRoot: config.outputRoot)
  }

  init(configError message: String) {
    configError = message
    dataRoot = ""
    outputRoot = ""
    sources = []
    onEndStages = []
    reloadConfig = { nil }
    connection = nil
    recentsProvider = RecentSessionsProvider(dataRoot: "", outputRoot: "")
    content = MenuContent(icon: .attention, header: "⚠ \(message)", verbs: [], pipeline: [])
  }

  func start() {
    guard let connection else { return }
    announcements.bootstrap(dataRoot: dataRoot, provider: recentsProvider) {
      [weak self] availability in
      self?.notifications = availability
    }
    observeMenuTracking()
    Task { await connection.run() }
    Task { await pump(connection) }
  }

  private func pump(_ connection: DaemonConnection) async {
    for await event in connection.events {
      switch event {
      case .ready(let daemon, let snapshot):
        MenuStateReducer.connected(&state, daemon: daemon, snapshot: snapshot)
        actionError = nil
        // Re-anchored on every (re)connect, so a restarted daemon's uptime
        // restarts with it instead of counting from the old process.
        anchorUptime(connection)
      case .event(let frame):
        switch MenuStateReducer.apply(&state, frame) {
        case .gap:
          // Only the first gap bounces: the frames already queued behind it are
          // from the same dead stream and all reduce to `.gap` too, and a bounce
          // each would redial in a loop.
          if state.connection == .connected {
            MenuStateReducer.resubscribing(&state)
            await connection.bounce()
          }
        case .applied:
          handleApplied(frame)
        case .ignoredStale:
          break
        }
      case .down:
        // Before reducing: the warning is edge-triggered off the state it is
        // dropping *from*.
        announcements.warnAtRisk(state: state)
        MenuStateReducer.disconnected(&state)
      }
      rerender()
    }
  }

  private func handleApplied(_ frame: EventFrame) {
    announcements.announce(frame, state: state)
    if RecentsRefreshPolicy.shouldRefresh(for: frame) {
      refreshRecents()
    }
  }

  /// Surfaces a failed control call: into the menu, where the user who clicked
  /// the verb is looking, and into unified logging for the after-the-fact
  /// question of why a session never ended.
  private func report(_ message: String) {
    log.error("control call failed: \(message, privacy: .public)")
    actionError = message
    rerender()
  }

  /// Runs a control call, reporting a rejection instead of dropping it.
  private func send(_ call: ControlCall, _ connection: DaemonConnection) {
    Task {
      if let error = await connection.perform(call) {
        report(error.message)
      } else {
        actionError = nil
      }
    }
  }

  func rerender() {
    // The config-error model has no connection and no state worth rendering:
    // its content *is* the error, installed once at init. Rendering the empty
    // `MenuState` over it would replace an actionable message with
    // "Connecting to earsd…" — a wait that never ends, because nothing is
    // dialling — the first time SwiftUI builds the menu.
    guard configError == nil else { return }
    content = MenuRenderer.render(state, now: Self.now())
  }

  func perform(_ verb: Verb) {
    guard let connection else { return }
    let call: ControlCall
    switch verb {
    case .startRecording:
      startRecording()
      return
    case .pause(let session): call = .sessionPause(session: session)
    case .resume(let session): call = .sessionResume(session: session)
    case .end(let session): call = .sessionEnd(session: session)
    case .rename(let session, let currentTitle):
      promptRename(session: session, currentTitle: currentTitle)
      return
    }
    send(call, connection)
  }

  func startRecording() {
    guard let connection else { return }
    // Against the config as it is *now*, not as it was at launch: the click
    // that follows a config edit must declare what the user just wrote.
    reloadDeclarations()
    // The daemon records exactly the sources a manual session names, skipping
    // any it doesn't know — so an empty list here is a session that captures
    // nothing while the menu happily reports "● Recording".
    guard !sources.isEmpty else {
      report("No capture sources are configured — see [[earsd.source]] in your config.")
      return
    }
    let title = DefaultSessionTitle.forManualStart(at: Self.now())
    // Declared, never inferred: the daemon runs no chain for a manual session
    // that doesn't ask, so "Stop → summary" is this app's promise to make.
    let params = SessionStartParams(title: title, sources: sources, onEndStages: onEndStages)
    send(.sessionStart(params), connection)
  }

  func dismiss(jobID: String) {
    MenuStateReducer.dismissJob(&state, id: jobID)
    rerender()
  }

  /// Called on every menu open, via `NSMenu.didBeginTracking` — see
  /// ``observeMenuTracking()``.
  func menuWillOpen() {
    // Re-renders before the menu draws because nothing here is asynchronous:
    // the uptime line derives from the clock, and `recents` is already kept
    // current by session/job events (``RecentsRefreshPolicy``). The disk scan
    // below is the belt-and-braces path for artifacts written by something
    // other than the daemon's own chain, and is allowed to land late.
    rerender()
    refreshRecents()
    reloadDeclarations()
  }

  /// Re-reads `sources`/`onEndStages` from the config layers. The rest of
  /// ``ClientConfig`` is deliberately not adopted: `socketPath` and the two
  /// roots are wired into a live `DaemonConnection` and a
  /// `RecentSessionsProvider` at init, and swapping those under a running app
  /// is a relaunch, not a refresh.
  private func reloadDeclarations() {
    guard let config = reloadConfig() else { return }
    sources = config.sources
    onEndStages = config.onEndStages
  }

  /// SwiftUI's menu-style `MenuBarExtra` gives the content view no per-open
  /// hook: `.onAppear` fires when the menu is first built and never again, so
  /// anything refreshed there is frozen at launch — a daemon that has been up
  /// for hours kept reporting the handful of seconds it had been up when the
  /// app started. AppKit still posts `didBeginTracking` for the status item's
  /// menu, which is the open event SwiftUI is missing. This app is
  /// `LSUIElement` with exactly one menu, so an unfiltered observation is
  /// precise in practice.
  private func observeMenuTracking() {
    Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(
        named: NSMenu.didBeginTrackingNotification)
      {
        guard let self else { return }
        self.menuWillOpen()
      }
    }
  }

  private func anchorUptime(_ connection: DaemonConnection) {
    Task { [weak self] in
      guard let seconds = await connection.status()?.uptimeSeconds else { return }
      self?.uptime = DaemonUptime(reported: Double(seconds), anchor: Self.now())
      self?.rerender()
    }
  }

  private static func now() -> Instant {
    Instant(secondsSinceEpoch: Date().timeIntervalSince1970)
  }

  private func refreshRecents() {
    let provider = recentsProvider
    Task.detached { [weak self] in
      let items = provider.load()
      await MainActor.run { self?.recents = items }
    }
  }

  private func promptRename(session: String, currentTitle: String) {
    guard let title = RenamePrompt.run(currentTitle: currentTitle), let connection else { return }
    send(.sessionRename(SessionRenameParams(session: session, title: title)), connection)
  }

  var daemonLine: String {
    guard let daemon = state.daemon else { return "Not connected" }
    guard let uptime else { return daemon }
    let seconds = uptime.seconds(at: Self.now())
    return "\(daemon) · up \(EarsMenuKit.ElapsedFormatter.compactDuration(seconds))"
  }

  func restartDaemon() {
    SystemActions.restartDaemon()
    guard let connection else { return }
    Task { await connection.bounce() }
  }
}
