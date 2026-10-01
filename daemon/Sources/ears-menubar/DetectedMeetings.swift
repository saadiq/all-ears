import EarsCore
import EarsMenuKit
import Observation
import UserNotifications

/// The menu bar's half of meeting detection: the daemon notices a meeting app
/// holding audio and says so in `meeting.activity`; this mirrors that
/// activity (``MeetingActivityReducer``), offers each active meeting as a
/// menu row (``MeetingOffers``) and as a prompt notification
/// (``MeetingPromptPolicy``), and turns an accepted offer into a session
/// (``DetectedMeetingControls``).
///
/// A slice of its own beside ``AppModel``'s menu state, so the fork's
/// detection layer leaves the stack's menu types untouched.
@MainActor @Observable final class DetectedMeetings {
  private(set) var state = MeetingActivityState()
  @ObservationIgnored private let controls: DetectedMeetingControls?
  @ObservationIgnored private let notifier: Notifier
  @ObservationIgnored private let prompted: PromptedEpisodeStore

  init(
    connection: DaemonConnection?, notifier: Notifier,
    prompted: PromptedEpisodeStore = PromptedEpisodeStore()
  ) {
    let calendar = CalendarProvider()
    controls = connection.map { DetectedMeetingControls(connection: $0, calendar: calendar) }
    self.notifier = notifier
    self.prompted = prompted
  }

  /// Registers the prompt's buttons; an accepted prompt goes to `onAccept`
  /// with its source and episode.
  func start(onAccept: @escaping @MainActor @Sendable (String, String) -> Void) {
    notifier.register(Self.promptCategory) { kind, userInfo in
      guard let accepted = MeetingPromptAcceptance.accepted(kind, userInfo: userInfo) else {
        return
      }
      onAccept(accepted.source, accepted.episode)
    }
  }

  /// Taken before a `status` catch-up is asked for — see
  /// ``MeetingActivityReducer/catchUp(_:_:ifEditsEqual:)``.
  var editMark: Int { state.edits }

  /// A fresh subscription. The prompt history is scoped to the daemon boot
  /// first, so no catch-up can prompt against a dead boot's history.
  func connected(bootID: String) {
    prompted.activate(bootID: bootID)
    MeetingActivityReducer.connected(&state)
  }

  func catchUp(_ activity: [MeetingActivityStatus], mark: Int) {
    MeetingActivityReducer.catchUp(&state, activity, ifEditsEqual: mark)
  }

  /// Applies a `meeting.activity` frame; returns whether the frame was one.
  @discardableResult
  func handle(_ frame: EventFrame) -> Bool {
    MeetingActivityReducer.apply(&state, frame)
  }

  func offers(menu: MenuState) -> [MeetingOffer] {
    MeetingOffers.render(state, menu: menu)
  }

  /// Prompts for any newly detected meeting the policy allows, and marks the
  /// episodes it prompts (or drops) so neither is offered again. A live
  /// session withdraws every standing offer; a meeting merely going inactive
  /// withdraws nothing — see ``MeetingPromptPolicy`` for why.
  func reconcile(menu: MenuState) {
    let decision = MeetingPromptPolicy.decide(
      activity: state, menu: menu, alreadyPrompted: prompted.episodes)
    notifier.withdraw(
      identifiers: decision.withdrawSources.map(
        MeetingPromptCategory.notificationIdentifier(source:)))
    for episode in decision.markPrompted { prompted.mark(episode) }
    for prompt in decision.post {
      notifier.post(
        title: prompt.title, body: prompt.body, userInfo: prompt.userInfo,
        identifier: prompt.notificationIdentifier, category: MeetingPromptCategory.identifier)
    }
  }

  /// Starts recording a meeting the daemon already detected. Returns why it
  /// failed, or `nil`.
  func accept(source: String, episode: String, menu: MenuState) async -> String? {
    // Answered, whichever way this call ends: accepted from the notification
    // macOS has already taken down, or from the menu row, where this app's
    // standing offer may still be on screen offering what is about to start.
    notifier.withdraw(identifiers: [MeetingPromptCategory.notificationIdentifier(source: source)])
    prompted.mark(episode)
    // An accept can arrive long after the offer, now that the prompt is
    // alert-style and recoverable from Notification Center: the menu only
    // offers the verb while idle, but a notification clicked after a session
    // started by other means lands here. The daemon records one session at a
    // time, so a second `session.start` would surface only as an error the
    // user did not cause.
    guard let controls, menu.activeSession == nil else { return nil }
    return await controls.start(source: SourceID(source), episode: episode)
  }

  /// The buttons on a detected-meeting prompt.
  ///
  /// Neither carries `.foreground`: this is an `LSUIElement` app with no
  /// window to raise, so activating it on a click would pull focus off the
  /// meeting being joined and show nothing for it. The system delivers the
  /// response to the running app either way.
  ///
  /// A `let`, not a computed property: the buttons are fixed. This type is
  /// `@MainActor`, which extends to its statics, so a non-`Sendable`
  /// `UNNotificationCategory` is legal stored here.
  private static let promptCategory = UNNotificationCategory(
    identifier: MeetingPromptCategory.identifier,
    actions: [
      UNNotificationAction(
        identifier: MeetingPromptCategory.start, title: "Start Recording", options: []),
      UNNotificationAction(
        identifier: MeetingPromptCategory.dismiss, title: "Not Now", options: []),
    ],
    intentIdentifiers: [], options: [])
}
