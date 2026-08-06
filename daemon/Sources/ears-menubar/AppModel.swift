import AppKit
import EarsCore
import EarsMenuKit
import Foundation
import Observation

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
  let configError: String?
  let dataRoot: String
  let outputRoot: String

  private let connection: DaemonConnection?

  init(config: ClientConfig) {
    configError = nil
    dataRoot = config.dataRoot
    outputRoot = config.outputRoot
    connection = DaemonConnection(socketPath: config.socketPath)
  }

  init(configError message: String) {
    configError = message
    dataRoot = ""
    outputRoot = ""
    connection = nil
    content = MenuContent(icon: .attention, header: "⚠ \(message)", verbs: [], pipeline: [])
  }

  func start() {
    guard let connection else { return }
    Task { await connection.run() }
    Task { await pump(connection) }
  }

  private func pump(_ connection: DaemonConnection) async {
    for await event in connection.events {
      switch event {
      case .ready(let daemon, let bootChanged, let snapshot):
        MenuStateReducer.connected(
          &state, daemon: daemon, bootChanged: bootChanged, snapshot: snapshot)
      case .event(let frame):
        switch MenuStateReducer.apply(&state, frame) {
        case .gap:
          await connection.bounce()
        case .applied:
          handleApplied(frame)
        case .ignoredStale:
          break
        }
      case .down:
        if let request = NotificationPolicy.onDisconnect(state: state) {
          post(request)
        }
        MenuStateReducer.disconnected(&state)
      }
      rerender()
    }
  }

  /// Notifier lands in Task 12; until then applied frames only trigger rerenders.
  private func handleApplied(_ frame: EventFrame) {
    if let request = NotificationPolicy.onEvent(frame, state: state) {
      post(request)
    }
  }

  private func post(_ request: NotificationRequest) {
    // Replaced by the Notifier in Task 12.
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
    Task { _ = await connection.perform(call) }
  }

  func startRecording() {
    guard let connection else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let title = "Recording \(formatter.string(from: Date()))"
    Task {
      _ = await connection.perform(
        .sessionStart(SessionStartParams(title: title, sources: [SourceID("mic")])))
    }
  }

  func dismiss(jobID: String) {
    MenuStateReducer.dismissJob(&state, id: jobID)
    rerender()
  }

  func menuWillOpen() {
    rerender()
    guard let connection else { return }
    Task {
      uptimeSeconds = await connection.status()?.uptimeSeconds
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
    Task {
      _ = await connection.perform(
        .sessionRename(SessionRenameParams(session: session, title: title)))
    }
  }
}
