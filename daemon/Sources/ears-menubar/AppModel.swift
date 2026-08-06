import AppKit
import EarsCore
import EarsDataStore
import EarsMenuKit
import Foundation
import Observation
import os

/// One ended session plus its located output files (Task 11 fills these in;
/// until then every AppModel leaves `recents` empty).
struct RecentSessionItem: Identifiable, Hashable, Sendable {
  var session: Session
  var transcript: URL?
  var clean: URL?
  var summaries: [URL]
  var id: String { session.id }
}

@MainActor @Observable final class AppModel {
  private(set) var state = MenuState()
  private(set) var content = MenuContent(
    icon: .idle, header: "Connecting to earsd…", verbs: [], pipeline: [])
  private(set) var recents: [RecentSessionItem] = []
  private(set) var uptimeSeconds: Int?
  /// The last control call that failed, kept for the menu to show. A verb that
  /// silently does nothing is the worst outcome here: the user walks away
  /// believing a recording stopped when it did not.
  private(set) var actionError: String?
  let configError: String?
  let dataRoot: String
  let outputRoot: String

  private let connection: DaemonConnection?
  private let recentsProvider: RecentSessionsProvider
  private let notifier = Notifier()
  private let sources: [SourceID]
  /// Sessions already warned about via "Recording at risk", so a crash-looping
  /// daemon warns once per session instead of once per crash.
  private var warnedAtRiskSessions: Set<String> = []
  private let log = Logger(subsystem: "net.tomelliot.ears.menubar", category: "app")

  init(config: ClientConfig) {
    configError = nil
    dataRoot = config.dataRoot
    outputRoot = config.outputRoot
    sources = config.sources
    connection = DaemonConnection(socketPath: config.socketPath)
    recentsProvider = RecentSessionsProvider(
      dataRoot: config.dataRoot, outputRoot: config.outputRoot)
  }

  init(configError message: String) {
    configError = message
    dataRoot = ""
    outputRoot = ""
    sources = []
    connection = nil
    recentsProvider = RecentSessionsProvider(dataRoot: "", outputRoot: "")
    content = MenuContent(icon: .attention, header: "⚠ \(message)", verbs: [], pipeline: [])
  }

  func start() {
    guard let connection else { return }
    let dataRoot = self.dataRoot
    let provider = recentsProvider
    notifier.bootstrap { action in
      switch action {
      case .openSummary(let session):
        return provider.load(limit: 50).first { $0.session.id == session }?.summaries.first
      case .revealSession(let session):
        return DataStoreLayout.sessionDirectory(
          dataRoot: URL(fileURLWithPath: dataRoot), sessionID: session)
      case .none:
        return nil
      }
    }
    Task { await connection.run() }
    Task { await pump(connection) }
  }

  private func pump(_ connection: DaemonConnection) async {
    for await event in connection.events {
      switch event {
      case .ready(let daemon, let snapshot):
        MenuStateReducer.connected(&state, daemon: daemon, snapshot: snapshot)
        actionError = nil
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
        warnAtRiskIfNeeded()
        MenuStateReducer.disconnected(&state)
      }
      rerender()
    }
  }

  private func handleApplied(_ frame: EventFrame) {
    if let request = NotificationPolicy.onEvent(frame, state: state) {
      post(request)
    }
    if case .job(let job) = frame.event, job.state == .done || job.state == .failed {
      refreshRecents()
    }
  }

  private func warnAtRiskIfNeeded() {
    guard let session = state.activeSession,
      let request = NotificationPolicy.onDisconnect(
        state: state, warnedSessions: warnedAtRiskSessions)
    else { return }
    warnedAtRiskSessions.insert(session.id)
    post(request)
  }

  private func post(_ request: NotificationRequest) {
    notifier.post(request)
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
    content = MenuRenderer.render(
      state, now: Instant(secondsSinceEpoch: Date().timeIntervalSince1970))
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
    // The daemon records exactly the sources a manual session names, skipping
    // any it doesn't know — so an empty list here is a session that captures
    // nothing while the menu happily reports "● Recording".
    guard !sources.isEmpty else {
      report("No capture sources are configured — see [[earsd.source]] in your config.")
      return
    }
    let title = DefaultSessionTitle.forManualStart(
      at: Instant(secondsSinceEpoch: Date().timeIntervalSince1970))
    send(.sessionStart(SessionStartParams(title: title, sources: sources)), connection)
  }

  func dismiss(jobID: String) {
    MenuStateReducer.dismissJob(&state, id: jobID)
    rerender()
  }

  func menuWillOpen() {
    rerender()
    refreshRecents()
    guard let connection else { return }
    Task {
      uptimeSeconds = await connection.status()?.uptimeSeconds
    }
  }

  private func refreshRecents() {
    let provider = recentsProvider
    Task.detached { [weak self] in
      let items = provider.load()
      await MainActor.run { self?.recents = items }
    }
  }

  private func promptRename(session: String, currentTitle: String) {
    // NSAlert with an accessory NSTextField; LSUIElement apps must activate first.
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Rename Session"
    let field = NSTextField(string: currentTitle)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn, let connection else { return }
    let title = field.stringValue
    guard !title.isEmpty else { return }
    send(.sessionRename(SessionRenameParams(session: session, title: title)), connection)
  }

  var daemonLine: String {
    guard let daemon = state.daemon else { return "Not connected" }
    guard let uptime = uptimeSeconds else { return daemon }
    return "\(daemon) · up \(EarsMenuKit.ElapsedFormatter.compactDuration(Double(uptime)))"
  }

  func restartDaemon() {
    SystemActions.restartDaemon()
    guard let connection else { return }
    Task { await connection.bounce() }
  }
}
