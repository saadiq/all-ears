import EarsCore
import EarsDataStore
import EarsMenuKit
import Foundation

/// The app's whole notification surface: what gets announced, whether it can
/// be delivered, and where a click on one lands.
///
/// ``NotificationPolicy`` decides *what* is worth saying and ``Notifier``
/// speaks to `UNUserNotificationCenter`; this owns the two pieces of state
/// that sit between them — the delivery grant and the per-session dedup of
/// the at-risk warning — so `AppModel` handles events rather than the
/// notification centre.
@MainActor final class SessionNotifications {
  /// Shared, not owned: `UNUserNotificationCenter` has one delegate, so every
  /// part of the app that posts or answers notifications goes through it.
  private let notifier: Notifier
  /// Sessions already warned about via "Recording at risk", so a crash-looping
  /// daemon warns once per session instead of once per crash.
  private var warnedAtRiskSessions: Set<String> = []

  init(notifier: Notifier) {
    self.notifier = notifier
  }

  /// Asks for the grant and wires notification clicks to the files they name.
  ///
  /// A click resolves off the main actor (the notifier's resolver is
  /// `@Sendable async`): falling back to a scan reads the session store, and a
  /// large store must not stall the menu bar.
  ///
  /// - Parameter report: receives the resolved availability, here and on every
  ///   later ``refreshAvailability(report:)``.
  func bootstrap(
    dataRoot: String, loader: RecentsLoader?,
    report: @escaping @MainActor @Sendable (NotificationAvailability) -> Void
  ) {
    notifier.bootstrap { action in
      switch action {
      case .openSummary(let session, let path):
        if let written = SummaryTarget.written(
          path, exists: FileManager.default.fileExists(atPath:))
        {
          return written
        }
        return loader?.summary(forSession: session, now: AppClock.now())
      case .revealSession(let session):
        return DataStoreLayout.sessionDirectory(
          dataRoot: URL(fileURLWithPath: dataRoot), sessionID: session)
      case .none:
        return nil
      }
    } report: { availability in
      report(availability)
    }
  }

  /// Re-reads the delivery grant — see ``Notifier/refreshAvailability(report:)``
  /// for why the launch-time answer cannot be trusted for the life of a login
  /// item.
  func refreshAvailability(
    report: @escaping @MainActor @Sendable (NotificationAvailability) -> Void
  ) {
    notifier.refreshAvailability(report: report)
  }

  /// Announces an applied event if the policy says it is worth announcing.
  /// `before` is the state the frame was applied to, which is how the policy
  /// tells a new failure from one it has already announced.
  func announce(_ frame: EventFrame, before: MenuState) {
    guard let request = NotificationPolicy.onEvent(frame, state: before) else { return }
    notifier.post(request)
  }

  /// Warns that the daemon went away mid-recording, at most once per session.
  func warnAtRisk(state: MenuState) {
    guard let session = state.activeSession,
      let request = NotificationPolicy.onDisconnect(
        state: state, warnedSessions: warnedAtRiskSessions)
    else { return }
    warnedAtRiskSessions.insert(session.id)
    notifier.post(request)
  }
}
