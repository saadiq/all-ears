import Testing

@testable import EarsMenuKit

@Suite("MeetingPromptResponse")
struct MeetingPromptResponseTests {
  private let prompt = MeetingPrompt(
    source: "app:us.zoom.xos", episode: "us.zoom.xos#1", label: "Zoom")
  private let accepted = MeetingPromptAcceptance(
    source: "app:us.zoom.xos", episode: "us.zoom.xos#1")

  @Test("the payload carries the action, source, episode and label")
  func userInfo() {
    #expect(
      prompt.userInfo == [
        "action": "startDetected", "source": "app:us.zoom.xos", "episode": "us.zoom.xos#1",
        "label": "Zoom",
      ])
  }

  @Test("a click on the body accepts")
  func bodyAccepts() {
    #expect(MeetingPromptAcceptance.accepted(.body, userInfo: prompt.userInfo) == accepted)
  }

  @Test("the Start Recording button accepts")
  func startAccepts() {
    let kind = NotificationResponseKind.button(MeetingPromptCategory.start)
    #expect(MeetingPromptAcceptance.accepted(kind, userInfo: prompt.userInfo) == accepted)
  }

  @Test("Not Now, an unknown button, and a system dismiss are ignored")
  func othersIgnored() {
    for kind: NotificationResponseKind in [
      .button(MeetingPromptCategory.dismiss), .button("snooze"), .other,
    ] {
      #expect(MeetingPromptAcceptance.accepted(kind, userInfo: prompt.userInfo) == nil)
    }
  }

  @Test("a payload that is not a meeting prompt, or lacks source or episode, is ignored")
  func malformedIgnored() {
    var wrongAction = prompt.userInfo
    wrongAction["action"] = "openSummary"
    var noSource = prompt.userInfo
    noSource["source"] = nil
    var noEpisode = prompt.userInfo
    noEpisode["episode"] = nil
    for info in [wrongAction, noSource, noEpisode, [:]] {
      #expect(MeetingPromptAcceptance.accepted(.body, userInfo: info) == nil)
    }
  }
}
