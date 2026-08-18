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
  /// Starts a detected session from a `.startDetected` click. Runs on the main
  /// actor directly rather than through `resolve` — there is no artifact URL
  /// to open, only a session to start.
  private var startDetected: (@MainActor @Sendable (String, String) -> Void)?
  private let log = Logger(subsystem: "net.tomelliot.ears.menubar", category: "notify")

  /// - Parameter report: called once the grant resolves, so the menu can say
  ///   that notifications are off. Every path reports, including the
  ///   no-bundle one — a caller that never hears back cannot tell "authorized"
  ///   from "the callback was dropped".
  func bootstrap(
    resolve: @escaping @Sendable (NotificationRequest.Action) async -> URL?,
    startDetected: @escaping @MainActor @Sendable (String, String) -> Void,
    report: @escaping @MainActor @Sendable (NotificationAvailability) -> Void
  ) {
    guard Bundle.main.bundleIdentifier != nil else {
      report(.unsupported)
      return
    }
    available = true
    self.resolve = resolve
    self.startDetected = startDetected
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([Self.meetingPromptCategory])
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
  /// only one the app ever hears — and it goes stale in both directions. A
  /// user who follows the menu's own "Open Notification Settings" and turns
  /// notifications *on* would otherwise keep the warning for the life of the
  /// process (indefinite, for a login item). Worse in reverse: a grant revoked
  /// after launch leaves the app believing it is authorized while macOS
  /// accepts every post and drops it — the exact silent failure
  /// ``NotificationAvailability`` exists to surface.
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

  /// The buttons on a detected-meeting prompt.
  ///
  /// Neither carries `.foreground`: this is an `LSUIElement` app with no
  /// window to raise, so activating it on a click would pull focus off the
  /// meeting being joined and show nothing for it. The system delivers the
  /// response to the running app either way.
  ///
  /// A `let`, not a computed property: the buttons are fixed. `Notifier` is
  /// `@MainActor`, which extends to its statics, so a non-`Sendable`
  /// `UNNotificationCategory` is legal stored here.
  private static let meetingPromptCategory = UNNotificationCategory(
    identifier: MeetingPromptCategory.identifier,
    actions: [
      UNNotificationAction(
        identifier: MeetingPromptCategory.start, title: "Start Recording", options: []),
      UNNotificationAction(
        identifier: MeetingPromptCategory.dismiss, title: "Not Now", options: []),
    ],
    intentIdentifiers: [], options: [])

  func post(_ request: NotificationRequest) {
    guard available else { return }
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.userInfo = Self.encode(request.action)
    content.categoryIdentifier = request.action.notificationCategory ?? ""
    // `requestAuthorization` has always asked for `.sound` and `willPresent`
    // has always returned it, but neither plays anything on its own — without
    // a sound on the content the grant is inert. A silent alert defeats the
    // point of one: the meeting prompt is worth interrupting for, and it is
    // shown while the user's attention is on the call they just joined.
    content.sound = .default
    let log = self.log
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(
        identifier: request.action.notificationIdentifier ?? UUID().uuidString,
        content: content, trigger: nil)
    ) { error in
      guard let error else { return }
      log.error("notification post failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Takes back the standing offer for each of `sources`, once answering it
  /// would do nothing — it was accepted, or a session is already running.
  ///
  /// An alert-style notification never fades, so an offer nobody can act on
  /// would otherwise sit there indefinitely. Note what this deliberately does
  /// *not* cover: a meeting merely ending. See ``AppModel/offerDetectedMeetings()``.
  ///
  /// Delivered only: a prompt is posted with no trigger, so there is never a
  /// pending request to cancel.
  func withdrawMeetingPrompts(sources: [String]) {
    guard available, !sources.isEmpty else { return }
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: sources.map(MeetingPromptCategory.notificationIdentifier(source:)))
  }

  nonisolated static func encode(_ action: NotificationRequest.Action) -> [String: String] {
    switch action {
    case .openSummary(let session): return ["action": "openSummary", "session": session]
    case .revealSession(let session): return ["action": "revealSession", "session": session]
    case .startDetected(let source, let episode, let label):
      return ["action": "startDetected", "source": source, "episode": episode, "label": label]
    case .none: return [:]
    }
  }

  /// Switches on `action` first, not on the presence of `session`: unlike the
  /// other two actions, `.startDetected` carries `source`/`episode`/`label`
  /// instead of a `session` key.
  nonisolated static func decode(_ userInfo: [AnyHashable: Any]) -> NotificationRequest.Action {
    switch userInfo["action"] as? String {
    case "openSummary":
      guard let session = userInfo["session"] as? String else { return .none }
      return .openSummary(session: session)
    case "revealSession":
      guard let session = userInfo["session"] as? String else { return .none }
      return .revealSession(session: session)
    case "startDetected":
      guard let source = userInfo["source"] as? String,
        let episode = userInfo["episode"] as? String
      else { return .none }
      return .startDetected(
        source: source, episode: episode, label: userInfo["label"] as? String ?? "")
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
    // Acting is the exception, not the default. Naming the two identifiers
    // that accept — a click on the body, and the Start button — means a
    // response this app does not understand is ignored rather than treated as
    // a yes: "Not Now", the system's own dismiss identifier if the category
    // ever gains `.customDismissAction`, and any button added later all fall
    // here. Declining needs no undo, since the episode was marked prompted
    // when the notification went out.
    switch response.actionIdentifier {
    case UNNotificationDefaultActionIdentifier, MeetingPromptCategory.start:
      break
    default:
      completionHandler()
      return
    }
    let userInfo = response.notification.request.content.userInfo
    let action = Notifier.decode(userInfo)
    Task { @MainActor [weak self] in
      if case .startDetected(let source, let episode, _) = action {
        self?.startDetected?(source, episode)
        return
      }
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
    // Notification Center is where a missed meeting prompt is recovered.
    completionHandler([.banner, .list, .sound])
  }
}
