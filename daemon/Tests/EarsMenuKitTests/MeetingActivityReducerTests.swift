import EarsCore
import Testing

@testable import EarsMenuKit

func zoomActivity(active: Bool = true, episode: String = "us.zoom.xos#1", label: String = "Zoom")
  -> MeetingActivityStatus
{
  MeetingActivityStatus(
    source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
    label: label, active: active, episode: episode)
}

@Suite("MeetingActivityReducer")
struct MeetingActivityReducerTests {
  @Test("meeting.activity telemetry upserts by source and applies without a rev")
  func upsertsBySource() {
    var state = MeetingActivityState()
    let began = zoomActivity()
    #expect(MeetingActivityReducer.apply(&state, EventFrame(event: .meetingActivity(began))))
    #expect(state.active == [began])
    let ended = zoomActivity(active: false)
    MeetingActivityReducer.apply(&state, EventFrame(event: .meetingActivity(ended)))
    #expect(state.active.isEmpty)
    #expect(state.activity == [ended])
  }

  @Test("a frame that is not meeting activity is ignored")
  func otherFramesIgnored() {
    var state = MeetingActivityState()
    let frame = EventFrame(event: .session(makeSession()), rev: 1)
    #expect(!MeetingActivityReducer.apply(&state, frame))
    #expect(state == MeetingActivityState())
  }

  @Test("connecting clears stale activity and bumps the edit counter")
  func connectedClears() {
    var state = MeetingActivityState()
    MeetingActivityReducer.apply(&state, EventFrame(event: .meetingActivity(zoomActivity())))
    let before = state.edits
    MeetingActivityReducer.connected(&state)
    #expect(state.activity.isEmpty)
    #expect(state.edits == before + 1)
  }

  @Test("a catch-up whose mark still matches applies")
  func catchUpApplies() {
    var state = MeetingActivityState()
    MeetingActivityReducer.connected(&state)
    let fresh = zoomActivity(episode: "us.zoom.xos#2")
    MeetingActivityReducer.catchUp(&state, [fresh], ifEditsEqual: state.edits)
    #expect(state.active == [fresh])
  }

  @Test("a catch-up issued before a reconnect never lands on the reconnected state")
  func catchUpFromBeforeAReconnectIsDiscarded() {
    var state = MeetingActivityState()
    MeetingActivityReducer.connected(&state)
    // The mark the first connection's catch-up captured before asking `status`.
    let mark = state.edits
    // The socket dropped and redialled before that answer arrived.
    MeetingActivityReducer.connected(&state)
    MeetingActivityReducer.catchUp(&state, [zoomActivity()], ifEditsEqual: mark)
    #expect(state.activity.isEmpty)
  }

  @Test("a live edge that lands while a status catch-up is in flight wins over it")
  func liveEdgeDuringCatchUpWins() {
    var state = MeetingActivityState()
    MeetingActivityReducer.connected(&state)
    // The mark a caller would capture right before asking the daemon for `status`.
    let mark = state.edits
    let ended = zoomActivity(active: false)
    MeetingActivityReducer.apply(&state, EventFrame(event: .meetingActivity(ended)))
    // The catch-up's answer arrives after the live edge — it's stale, so it
    // must not clobber the edge it raced.
    MeetingActivityReducer.catchUp(&state, [zoomActivity()], ifEditsEqual: mark)
    #expect(state.activity == [ended])
    // A catch-up whose mark matches the current count applies normally.
    let fresh = zoomActivity(episode: "us.zoom.xos#2")
    MeetingActivityReducer.catchUp(&state, [fresh], ifEditsEqual: state.edits)
    #expect(state.active == [fresh])
  }
}
