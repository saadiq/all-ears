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

  @Test("the prompt names the category that carries its buttons")
  func promptCarriesActionCategory() {
    let prompts = MeetingPromptPolicy.prompts(
      state: connectedState([zoomActive()]), alreadyPrompted: [])
    #expect(prompts[0].request.category == MeetingPromptCategory.identifier)
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
      DetectedSessionIdentity.platform(forBundleID: "com.example.other") == "com.example.other")
  }
}
