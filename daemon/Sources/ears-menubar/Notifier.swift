import AppKit
import EarsMenuKit
import UserNotifications
import os

/// UNUserNotificationCenter requires a real bundle; a bare `swift run` binary
/// has none, so the notifier degrades to a no-op there (bundle-gated).
@MainActor
final class Notifier: NSObject {
  private var available = false
  /// `async` and `@Sendable`, so it does not inherit this actor: resolving a
  /// click reads the session store, which must not run on the main actor.
  private var resolve: (@Sendable (NotificationRequest.Action) async -> URL?)?
  private let log = Logger(subsystem: "net.tomelliot.ears.menubar", category: "notify")

  /// - Parameter report: called once the grant resolves, so the menu can say
  ///   that notifications are off. Every path reports, including the
  ///   no-bundle one — a caller that never hears back cannot tell "authorized"
  ///   from "the callback was dropped".
  func bootstrap(
    resolve: @escaping @Sendable (NotificationRequest.Action) async -> URL?,
    report: @escaping @MainActor @Sendable (NotificationAvailability) -> Void
  ) {
    guard Bundle.main.bundleIdentifier != nil else {
      report(.unsupported)
      return
    }
    available = true
    self.resolve = resolve
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let log = self.log
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      // Arrives off the main actor, and `report` mutates the model.
      Task { @MainActor in
        if let error {
          log.error(
            "notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        if !granted {
          log.error("notification authorization denied: results will not be announced")
        }
        report(granted ? .authorized : .denied)
      }
    }
  }

  func post(_ request: NotificationRequest) {
    guard available else { return }
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.userInfo = Self.encode(request.action)
    let log = self.log
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    ) { error in
      guard let error else { return }
      log.error("notification post failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  nonisolated static func encode(_ action: NotificationRequest.Action) -> [String: String] {
    switch action {
    case .openSummary(let session): return ["action": "openSummary", "session": session]
    case .revealSession(let session): return ["action": "revealSession", "session": session]
    case .none: return [:]
    }
  }

  nonisolated static func decode(_ userInfo: [AnyHashable: Any]) -> NotificationRequest.Action {
    guard let session = userInfo["session"] as? String else { return .none }
    switch userInfo["action"] as? String {
    case "openSummary": return .openSummary(session: session)
    case "revealSession": return .revealSession(session: session)
    default: return .none
    }
  }
}

extension Notifier: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    let action = Notifier.decode(userInfo)
    Task { @MainActor [weak self] in
      guard let resolve = self?.resolve, let url = await resolve(action) else { return }
      switch action {
      case .revealSession: NSWorkspace.shared.activateFileViewerSelecting([url])
      default: NSWorkspace.shared.open(url)
      }
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
