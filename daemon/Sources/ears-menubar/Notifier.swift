import AppKit
import EarsMenuKit
import UserNotifications

/// UNUserNotificationCenter requires a real bundle; a bare `swift run` binary
/// has none, so the notifier degrades to a no-op there (bundle-gated).
@MainActor
final class Notifier: NSObject {
  private var available = false
  private var resolve: (@Sendable (NotificationRequest.Action) -> URL?)?

  func bootstrap(resolve: @escaping @Sendable (NotificationRequest.Action) -> URL?) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    available = true
    self.resolve = resolve
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func post(_ request: NotificationRequest) {
    guard available else { return }
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.userInfo = Self.encode(request.action)
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
      guard let url = self?.resolve?(action) else { return }
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
