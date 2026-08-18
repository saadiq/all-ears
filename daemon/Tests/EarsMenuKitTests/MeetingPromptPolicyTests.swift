import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("Meeting prompt policy")
struct MeetingPromptPolicyTests {
  private func zoomActive(_ episode: String = "us.zoom.xos#1") -> MeetingActivityStatus {
    MeetingActivityStatus(
      source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
      label: "Zoom", active: true, episode: episode)
  }
  private func connectedState(_ activity: [MeetingActivityStatus]) -> MenuState {
    var state = MenuState()
    state.connection = .connected
    state.meetingActivity = activity
    return state
  }

  @Test("an active meeting with no live session prompts once")
  func promptsForActiveMeeting() {
    let prompts = MeetingPromptPolicy.prompts(
      state: connectedState([zoomActive()]), alreadyPrompted: [])
    #expect(prompts.count == 1)
    #expect(prompts[0].episode == "us.zoom.xos#1")
    #expect(prompts[0].request.title == "Zoom meeting detected")
    #expect(
      prompts[0].request.action
        == .startDetected(source: "app:us.zoom.xos", episode: "us.zoom.xos#1", label: "Zoom"))
  }

  @Test("only an offer to start carries the prompt's buttons")
  func onlyOffersCarryTheButtonCategory() {
    let offer = NotificationRequest.Action.startDetected(
      source: "app:us.zoom.xos", episode: "us.zoom.xos#1", label: "Zoom")
    #expect(offer.notificationCategory == MeetingPromptCategory.identifier)
    // A notification that accepts nothing must not offer Start / Not Now.
    #expect(NotificationRequest.Action.openSummary(session: "s1").notificationCategory == nil)
    #expect(NotificationRequest.Action.revealSession(session: "s1").notificationCategory == nil)
    #expect(NotificationRequest.Action.none.notificationCategory == nil)
  }

  @Test("only an offer to start is posted under a withdrawable id")
  func onlyOffersCarryAStableNotificationID() {
    let offer = NotificationRequest.Action.startDetected(
      source: "app:us.zoom.xos", episode: "us.zoom.xos#1", label: "Zoom")
    // Keyed on the episode, so the app can take the offer back once it stops
    // standing — and so two posts for one episode replace rather than stack.
    #expect(
      offer.notificationIdentifier
        == MeetingPromptCategory.notificationIdentifier(episode: "us.zoom.xos#1"))
    #expect(
      MeetingPromptCategory.notificationIdentifier(episode: "us.zoom.xos#1")
        != MeetingPromptCategory.notificationIdentifier(episode: "us.zoom.xos#2"))
    // History, not an offer: a fresh id per post, so a second summary never
    // overwrites the first.
    #expect(NotificationRequest.Action.openSummary(session: "s1").notificationIdentifier == nil)
    #expect(NotificationRequest.Action.revealSession(session: "s1").notificationIdentifier == nil)
    #expect(NotificationRequest.Action.none.notificationIdentifier == nil)
  }

  @Test("an already-prompted episode stays quiet")
  func dedupsByEpisode() {
    let prompts = MeetingPromptPolicy.prompts(
      state: connectedState([zoomActive()]), alreadyPrompted: ["us.zoom.xos#1"])
    #expect(prompts.isEmpty)
  }

  @Test("a live session suppresses (drops) the prompt")
  func activeSessionSuppresses() {
    var state = connectedState([zoomActive()])
    state.sessions = [
      Session(id: "s1", title: "t", state: .active, started: Instant(secondsSinceEpoch: 0))
    ]
    #expect(MeetingPromptPolicy.prompts(state: state, alreadyPrompted: []).isEmpty)
  }

  @Test("ended activity never prompts")
  func endedActivityQuiet() {
    var ended = zoomActive()
    ended.active = false
    #expect(
      MeetingPromptPolicy.prompts(state: connectedState([ended]), alreadyPrompted: []).isEmpty)
  }

  @Test("bundle ids map to platform slugs with a bundle-id fallback")
  func platformSlugs() {
    #expect(DetectedSessionIdentity.platform(forBundleID: "us.zoom.xos") == "zoom-app")
    #expect(DetectedSessionIdentity.platform(forBundleID: "com.microsoft.teams2") == "teams-app")
    #expect(
      DetectedSessionIdentity.platform(forBundleID: "com.tinyspeck.slackmacgap") == "slack-app")
    #expect(
      DetectedSessionIdentity.platform(forBundleID: "com.example.other") == "com.example.other")
  }
}
