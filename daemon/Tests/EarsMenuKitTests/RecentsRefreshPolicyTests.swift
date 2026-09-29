import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("RecentsRefreshPolicy")
struct RecentsRefreshPolicyTests {
  @Test("a session reaching ended refreshes, even with no chain behind it")
  func endedSessionRefreshes() {
    let frame = EventFrame(event: .session(makeSession(state: .ended)), rev: 42)
    #expect(RecentsRefreshPolicy.shouldRefresh(for: frame))
  }

  @Test("a finished job refreshes so the row's artifact items go live")
  func finishedJobRefreshes() {
    for state in [JobState.done, .failed] {
      let frame = EventFrame(
        event: .job(JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: state)))
      #expect(RecentsRefreshPolicy.shouldRefresh(for: frame))
    }
  }

  @Test("nothing that leaves the list unchanged triggers a scan")
  func quietEvents() {
    let quiet: [EarsEvent] = [
      .session(makeSession(state: .active)),
      .session(makeSession(state: .paused)),
      .job(JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: .started)),
      .source(id: SourceID("mic"), state: .paused),
      .vad(source: SourceID("mic"), state: .speech, t: instant(1_000)),
    ]
    for event in quiet {
      #expect(!RecentsRefreshPolicy.shouldRefresh(for: EventFrame(event: event, rev: 42)))
    }
  }
}
