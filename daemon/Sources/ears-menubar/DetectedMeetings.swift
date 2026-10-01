import EarsCore
import EarsMenuKit
import Observation

/// The menu bar's half of meeting detection: the daemon notices a meeting app
/// holding audio and says so in `meeting.activity`; this mirrors that
/// activity (``MeetingActivityReducer``), offers each active meeting as a
/// menu row (``MeetingOffers``), and turns an accepted offer into a session
/// (``DetectedMeetingControls``).
///
/// A slice of its own beside ``AppModel``'s menu state, so the fork's
/// detection layer leaves the stack's menu types untouched.
@MainActor @Observable final class DetectedMeetings {
  private(set) var state = MeetingActivityState()
  @ObservationIgnored private let controls: DetectedMeetingControls?

  init(connection: DaemonConnection?) {
    controls = connection.map { DetectedMeetingControls(connection: $0) }
  }

  /// Taken before a `status` catch-up is asked for — see
  /// ``MeetingActivityReducer/catchUp(_:_:ifEditsEqual:)``.
  var editMark: Int { state.edits }

  func connected() {
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

  /// Starts recording a meeting the daemon already detected. Returns why it
  /// failed, or `nil`.
  ///
  /// An accept can arrive long after the offer: the menu only offers the
  /// verb while idle, but a session started by other means may already be
  /// live. The daemon records one session at a time, so a second
  /// `session.start` would surface only as an error the user did not cause —
  /// it is dropped silently instead.
  func accept(source: String, episode: String, menu: MenuState) async -> String? {
    guard let controls, menu.activeSession == nil else { return nil }
    return await controls.start(source: SourceID(source), episode: episode)
  }
}
