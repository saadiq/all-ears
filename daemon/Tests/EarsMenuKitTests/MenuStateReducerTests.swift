import EarsCore
import Testing

@testable import EarsMenuKit

func instant(_ seconds: Double) -> Instant { Instant(secondsSinceEpoch: seconds) }

func makeSession(
  id: String = "s1", title: String = "Weekly sync", state: SessionState = .active,
  started: Double = 1_000
) -> Session {
  Session(
    id: id, title: title, state: state, started: instant(started),
    intervals: [SessionInterval(start: instant(started))], sources: [SourceID("mic")])
}

func makeSnapshot(rev: Int = 41, sessions: [Session] = [], sources: [SourceStatus] = [])
  -> SnapshotData
{
  SnapshotData(rev: rev, sessions: sessions, sources: sources)
}

@Suite("MenuStateReducer: connection + snapshot")
struct ConnectionReductionTests {
  @Test("a fresh state is connecting and empty")
  func freshState() {
    let state = MenuState()
    #expect(state.connection == .connecting)
    #expect(state.sessions.isEmpty && state.jobs.isEmpty && state.lastRev == nil)
  }

  @Test("connected() installs the snapshot and daemon identity")
  func connectedInstallsSnapshot() {
    var state = MenuState()
    let session = makeSession()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", bootChanged: false,
      snapshot: makeSnapshot(rev: 41, sessions: [session]))
    #expect(state.connection == .connected)
    #expect(state.daemon == "earsd 0.1.0")
    #expect(state.sessions == [session])
    #expect(state.lastRev == 41)
  }

  @Test("a boot change drops non-terminal jobs but keeps failures visible")
  func bootChangePrunesJobs() {
    var state = MenuState()
    state.jobs = [
      JobPublishParams(job: "a", kind: "transcribe", session: "s1", state: .running),
      JobPublishParams(job: "b", kind: "summarize", session: "s0", state: .failed),
    ]
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", bootChanged: true, snapshot: makeSnapshot())
    #expect(state.jobs.map(\.job) == ["b"])
  }

  @Test("disconnected() flips the phase and keeps last-known state for display")
  func disconnectedKeepsState() {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", bootChanged: false,
      snapshot: makeSnapshot(sessions: [makeSession()]))
    MenuStateReducer.disconnected(&state)
    #expect(state.connection == .unreachable)
    #expect(state.sessions.count == 1)
  }
}
