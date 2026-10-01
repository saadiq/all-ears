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

  /// Re-reads the grant and reports it.
  ///
  /// The prompt is one-shot, so ``bootstrap(resolve:report:)``'s answer is the
  /// only one the app ever hears, and it goes stale in both directions: a
  /// user who turns notifications back on from the menu's own shortcut would
  /// keep the warning for the life of the process, and a grant revoked after
  /// launch would leave the app believing it is authorized while macOS drops
  /// every post — the silent failure ``NotificationAvailability`` exists to
  /// surface.
  func refreshAvailability(
    report: @escaping @MainActor @Sendable (NotificationAvailability) -> Void
  ) {
    guard available else { return }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      // Read the one field here — `UNNotificationSettings` is not `Sendable`,
      // so only the resolved availability crosses to the main actor, where
      // `report` mutates the model.
      //
      // `.notDetermined` only survives a failed request; treat it like the
      // pre-answer state and stay quiet rather than warn about a grant the
      // user has not been asked for.
      let availability: NotificationAvailability =
        settings.authorizationStatus == .denied ? .denied : .authorized
      Task { @MainActor in report(availability) }
    }
  }

  func post(_ request: NotificationRequest) {
    guard available else { return }
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.userInfo = Self.encode(request.action)
    // The `.sound` grant plays nothing on its own; the content has to ask.
    content.sound = .default
    let log = self.log
    // A fresh id per post: each notification is history the moment it lands,
    // and a stable id would let a second summary overwrite the first.
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    ) { error in
      guard let error else { return }
      log.error("notification post failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  nonisolated static func encode(_ action: NotificationRequest.Action) -> [String: String] {
    switch action {
    case .openSummary(let session, let path):
      var info = ["action": "openSummary", "session": session]
      if let path { info["path"] = path }
      return info
    case .revealSession(let session): return ["action": "revealSession", "session": session]
    case .none: return [:]
    }
  }

  nonisolated static func decode(_ userInfo: [AnyHashable: Any]) -> NotificationRequest.Action {
    guard let session = userInfo["session"] as? String else { return .none }
    switch userInfo["action"] as? String {
    case "openSummary": return .openSummary(session: session, path: userInfo["path"] as? String)
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
    // Only a click on the body acts; any other response (a system dismiss,
    // say) is acknowledged and ignored rather than treated as a click.
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
      completionHandler()
      return
    }
    let action = Notifier.decode(response.notification.request.content.userInfo)
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
    // `.list` too: this fires only while the app is frontmost, and without it
    // a notification presented in that window is gone for good once it fades.
    completionHandler([.banner, .list, .sound])
  }
}
