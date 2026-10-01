import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("Meeting prompt policy")
struct MeetingPromptPolicyTests {
  private func menu(connected: Bool = true, sessions: [Session] = []) -> MenuState {
    var state = MenuState()
    if connected {
      MenuStateReducer.connected(
        &state, daemon: "earsd", snapshot: makeSnapshot(sessions: sessions))
    }
    return state
  }

  private func activity(_ list: [MeetingActivityStatus]) -> MeetingActivityState {
    var state = MeetingActivityState()
    state.activity = list
    return state
  }

  private let teams = MeetingActivityStatus(
    source: SourceID("app:com.microsoft.teams2"), bundleID: "com.microsoft.teams2",
    label: "Teams", active: false, episode: "com.microsoft.teams2#1")

  @Test("an active meeting with no live session prompts once")
  func promptsForActiveMeeting() {
    let decision = MeetingPromptPolicy.decide(
      activity: activity([zoomActivity()]), menu: menu(), alreadyPrompted: [])
    #expect(
      decision.post == [
        MeetingPrompt(source: "app:us.zoom.xos", episode: "us.zoom.xos#1", label: "Zoom")
      ])
    #expect(decision.post.first?.title == "Zoom meeting detected")
    #expect(decision.post.first?.body == "Start recording?")
    #expect(decision.markPrompted == ["us.zoom.xos#1"])
    #expect(decision.withdrawSources.isEmpty)
  }

  @Test("an already-prompted episode stays quiet")
  func dedupsByEpisode() {
    let decision = MeetingPromptPolicy.decide(
      activity: activity([zoomActivity()]), menu: menu(), alreadyPrompted: ["us.zoom.xos#1"])
    #expect(decision == MeetingPromptDecision())
  }

  @Test("a live session drops the episode and withdraws every known source's prompt")
  func liveSessionDropsAndWithdraws() {
    let decision = MeetingPromptPolicy.decide(
      activity: activity([zoomActivity(), teams]), menu: menu(sessions: [makeSession()]),
      alreadyPrompted: [])
    #expect(decision.post.isEmpty)
    // Inactive sources too: a prompt posted before its episode ended may still be on screen.
    #expect(decision.withdrawSources == ["app:us.zoom.xos", "app:com.microsoft.teams2"])
    // Dropped, not deferred: marking it prompted is what encodes the drop.
    #expect(decision.markPrompted == ["us.zoom.xos#1"])
  }

  @Test("a paused session counts as live")
  func pausedSessionCountsAsLive() {
    let decision = MeetingPromptPolicy.decide(
      activity: activity([zoomActivity()]),
      menu: menu(sessions: [makeSession(state: .paused)]), alreadyPrompted: [])
    #expect(decision.post.isEmpty)
    #expect(decision.markPrompted == ["us.zoom.xos#1"])
  }

  @Test("ended activity never prompts")
  func endedActivityQuiet() {
    let decision = MeetingPromptPolicy.decide(
      activity: activity([zoomActivity(active: false)]), menu: menu(), alreadyPrompted: [])
    #expect(decision == MeetingPromptDecision())
  }

  @Test("nothing happens while not connected")
  func notConnectedQuiet() {
    let decision = MeetingPromptPolicy.decide(
      activity: activity([zoomActivity()]), menu: menu(connected: false), alreadyPrompted: [])
    #expect(decision == MeetingPromptDecision())
  }

  @Test("prompts are re-evaluated when activity changes or a session starts or ends")
  func reconcileTriggers() {
    let idle = menu()
    let live = menu(sessions: [makeSession()])
    let paused = menu(sessions: [makeSession(state: .paused)])
    // An accepted offer (or a session started any other way) must withdraw the
    // other sources' standing prompts without waiting for a meeting frame.
    #expect(MeetingPromptPolicy.needsReconcile(activityChanged: false, before: idle, after: live))
    #expect(MeetingPromptPolicy.needsReconcile(activityChanged: false, before: live, after: idle))
    #expect(MeetingPromptPolicy.needsReconcile(activityChanged: true, before: idle, after: idle))
    #expect(!MeetingPromptPolicy.needsReconcile(activityChanged: false, before: idle, after: idle))
    // Pausing keeps the session live, so nothing about the offers changes.
    #expect(
      !MeetingPromptPolicy.needsReconcile(activityChanged: false, before: live, after: paused))
  }

  @Test("prompts are posted under one id per source, not per episode")
  func notificationIDIsPerSource() {
    let first = MeetingPrompt(source: "app:us.zoom.xos", episode: "us.zoom.xos#1", label: "Zoom")
    let later = MeetingPrompt(source: "app:us.zoom.xos", episode: "us.zoom.xos#2", label: "Zoom")
    let other = MeetingPrompt(
      source: "app:com.microsoft.teams2", episode: "com.microsoft.teams2#1", label: "Teams")
    #expect(first.notificationIdentifier == "meeting-detected:app:us.zoom.xos")
    #expect(first.notificationIdentifier == later.notificationIdentifier)
    #expect(first.notificationIdentifier != other.notificationIdentifier)
  }
}
