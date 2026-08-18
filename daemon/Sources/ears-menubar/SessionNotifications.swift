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
  private let notifier = Notifier()
  /// Sessions already warned about via "Recording at risk", so a crash-looping
  /// daemon warns once per session instead of once per crash.
  private var warnedAtRiskSessions: Set<String> = []

  /// Asks for the grant and wires notification clicks to the artifacts they
  /// name.
  ///
  /// - Parameter startDetected: called on a `.startDetected` click, with the
  ///   source and episode to start recording.
  /// - Parameter report: receives the resolved availability, here and on every
  ///   later ``refreshAvailability(report:)``.
  func bootstrap(
    dataRoot: String, provider: RecentSessionsProvider,
    startDetected: @escaping @MainActor @Sendable (String, String) -> Void,
    report: @escaping @MainActor @Sendable (NotificationAvailability) -> Void
  ) {
    // `@Sendable` and `async`, so resolving a click never runs the provider's
    // whole-store scan on the main actor — the click arrives on it, and a store
    // with thousands of sessions would beachball the menu bar.
    notifier.bootstrap { action in
      switch action {
      case .openSummary(let session):
        return provider.load(limit: 50).first { $0.session.id == session }?.summaries.first
      case .revealSession(let session):
        return DataStoreLayout.sessionDirectory(
          dataRoot: URL(fileURLWithPath: dataRoot), sessionID: session)
      case .startDetected, .none:
        return nil
      }
    } startDetected: { source, episode in
      startDetected(source, episode)
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
  func announce(_ frame: EventFrame, state: MenuState) {
    guard let request = NotificationPolicy.onEvent(frame, state: state) else { return }
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

  /// Posts detection prompts the policy produced. The caller marks the
  /// episodes prompted.
  func announceMeetingPrompts(_ prompts: [MeetingPrompt]) {
    for prompt in prompts { notifier.post(prompt.request) }
  }

  /// Takes back prompts for episodes that are no longer worth offering — see
  /// ``Notifier/withdrawMeetingPrompts(episodes:)``.
  func withdrawMeetingPrompts(_ episodes: [String]) {
    notifier.withdrawMeetingPrompts(episodes: episodes)
  }
}
