import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("MenuRenderer")
struct MenuRendererTests {
  func state(
    _ phase: ConnectionPhase = .connected, sessions: [Session] = [],
    jobs: [JobPublishParams] = []
  ) -> MenuState {
    var state = MenuState()
    if phase != .connecting {
      MenuStateReducer.connected(
        &state, daemon: "earsd 0.1.0", bootChanged: false,
        snapshot: makeSnapshot(rev: 41, sessions: sessions))
    }
    if phase == .unreachable { MenuStateReducer.disconnected(&state) }
    state.jobs = jobs
    return state
  }

  @Test("recording header carries the mark, title, and elapsed clock")
  func recordingHeader() {
    let content = MenuRenderer.render(
      state(sessions: [makeSession(started: 1_000)]), now: instant(1_723))
    #expect(content.header == "● Recording · Weekly sync · 12:03")
    #expect(content.icon == .recording)
    #expect(
      content.verbs == [
        .pause(session: "s1"), .rename(session: "s1", currentTitle: "Weekly sync"),
        .end(session: "s1"),
      ])
  }

  @Test("a paused session renders the paused mark, icon, and resume verb")
  func pausedHeader() {
    let content = MenuRenderer.render(
      state(sessions: [makeSession(state: .paused, started: 1_000)]), now: instant(1_063))
    #expect(content.header == "⏸ Paused · Weekly sync · 1:03")
    #expect(content.icon == .paused)
    #expect(content.verbs.first == .resume(session: "s1"))
  }

  @Test("idle shows only Start Recording")
  func idleContent() {
    let content = MenuRenderer.render(state(), now: instant(0))
    #expect(content.header == "Idle")
    #expect(content.icon == .idle)
    #expect(content.verbs == [.startRecording])
  }

  @Test("an unreachable daemon shows attention and no verbs")
  func unreachableContent() {
    let content = MenuRenderer.render(state(.unreachable), now: instant(0))
    #expect(content.header == "⚠ Daemon not running")
    #expect(content.icon == .attention)
    #expect(content.verbs.isEmpty)
  }

  @Test("connecting is idle-iconed with a connecting header")
  func connectingContent() {
    let content = MenuRenderer.render(state(.connecting), now: instant(0))
    #expect(content.header == "Connecting to earsd…")
    #expect(content.icon == .idle)
  }

  @Test("running jobs render busy lines titled by their session")
  func pipelineLines() {
    let jobs = [
      JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: .running)
    ]
    let content = MenuRenderer.render(
      state(sessions: [makeSession(state: .ended)], jobs: jobs), now: instant(0))
    #expect(content.icon == .busy)
    #expect(content.pipeline == [PipelineLine(text: "Transcribing ‘Weekly sync’…")])
  }

  @Test("a failed job renders a dismissible attention line and wins the icon")
  func failedJobLine() {
    let jobs = [
      JobPublishParams(job: "sum-1", kind: "summarize", session: "s1", state: .failed)
    ]
    let content = MenuRenderer.render(
      state(sessions: [makeSession(state: .ended)], jobs: jobs), now: instant(0))
    #expect(content.icon == .attention)
    #expect(
      content.pipeline == [
        PipelineLine(text: "⚠ Summary failed — Weekly sync", dismissibleJobID: "sum-1")
      ])
  }

  @Test("recording outranks a failed job for the icon")
  func recordingOutranksAttention() {
    let jobs = [
      JobPublishParams(job: "sum-1", kind: "summarize", session: "s0", state: .failed)
    ]
    let content = MenuRenderer.render(
      state(sessions: [makeSession()], jobs: jobs), now: instant(1_001))
    #expect(content.icon == .recording)
  }
}

@Suite("ElapsedFormatter")
struct ElapsedFormatterTests {
  @Test("clock renders m:ss below an hour and h:mm:ss above")
  func clockFormats() {
    #expect(ElapsedFormatter.clock(63) == "1:03")
    #expect(ElapsedFormatter.clock(723) == "12:03")
    #expect(ElapsedFormatter.clock(3_723) == "1:02:03")
    #expect(ElapsedFormatter.clock(-5) == "0:00")
  }

  @Test("compactDuration picks a humane unit")
  func compactFormats() {
    #expect(ElapsedFormatter.compactDuration(42) == "42s")
    #expect(ElapsedFormatter.compactDuration(180) == "3m")
    #expect(ElapsedFormatter.compactDuration(11_520) == "3h 12m")
    #expect(ElapsedFormatter.compactDuration(90_000) == "1d 1h")
  }
}
