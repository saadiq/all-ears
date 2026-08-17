import EarsCore
import Testing

@testable import EarsMenuKit

func instant(_ seconds: Double) -> Instant { Instant(secondsSinceEpoch: seconds) }

func makeSession(
  id: String = "s1", title: String = "Weekly sync", state: SessionState = .active,
  started: Double = 1_000, warnings: [String] = []
) -> Session {
  Session(
    id: id, title: title, state: state, started: instant(started),
    intervals: [SessionInterval(start: instant(started))], warnings: warnings,
    sources: [SourceID("mic")])
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
      &state, daemon: "earsd 0.1.0",
      snapshot: makeSnapshot(rev: 41, sessions: [session]))
    #expect(state.connection == .connected)
    #expect(state.daemon == "earsd 0.1.0")
    #expect(state.sessions == [session])
    #expect(state.lastRev == 41)
  }

  @Test("every (re)connect drops in-flight job telemetry, keeping failures visible")
  func everyConnectPrunesInFlightJobs() {
    var state = MenuState()
    state.jobs = [
      JobPublishParams(job: "a", kind: "transcribe", session: "s1", state: .started),
      JobPublishParams(job: "b", kind: "transcribe", session: "s1", state: .running),
      JobPublishParams(job: "c", kind: "summarize", session: "s1", state: .done),
      JobPublishParams(job: "d", kind: "summarize", session: "s0", state: .failed),
    ]
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", snapshot: makeSnapshot())
    #expect(state.jobs.map(\.job) == ["d"])
  }

  @Test("disconnected() flips the phase and keeps last-known state for display")
  func disconnectedKeepsState() {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0",
      snapshot: makeSnapshot(sessions: [makeSession()]))
    MenuStateReducer.disconnected(&state)
    #expect(state.connection == .unreachable)
    #expect(state.sessions.count == 1)
  }

  @Test("resubscribing() stops claiming a live connection and re-arms the gap check")
  func resubscribingLeavesConnected() {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0",
      snapshot: makeSnapshot(sessions: [makeSession()]))
    MenuStateReducer.resubscribing(&state)
    #expect(state.connection == .connecting)
    #expect(state.lastRev == nil)
    // The socket is gone, so the menu must not offer verbs against it.
    #expect(MenuRenderer.render(state, now: instant(1_001)).verbs.isEmpty)
    // Every frame still queued from the dead stream reduces to `.gap` too.
    #expect(
      MenuStateReducer.apply(&state, EventFrame(event: .session(makeSession()), rev: 42)) == .gap)
  }
}

@Suite("MenuStateReducer: event application")
struct EventApplicationTests {
  func connectedState(rev: Int = 41, sessions: [Session] = [makeSession()]) -> MenuState {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0",
      snapshot: makeSnapshot(rev: rev, sessions: sessions))
    return state
  }

  @Test("an in-order session event upserts and advances lastRev")
  func inOrderSessionApplies() {
    var state = connectedState(rev: 41)
    var renamed = makeSession()
    renamed.title = "Renamed"
    renamed.rev = 42
    let outcome = MenuStateReducer.apply(&state, EventFrame(event: .session(renamed), rev: 42))
    #expect(outcome == .applied)
    #expect(state.sessions.map(\.title) == ["Renamed"])
    #expect(state.lastRev == 42)
  }

  @Test("an unseen session id appends")
  func unseenSessionAppends() {
    var state = connectedState(rev: 41)
    let other = makeSession(id: "s2", title: "Standup")
    let outcome = MenuStateReducer.apply(&state, EventFrame(event: .session(other), rev: 42))
    #expect(outcome == .applied)
    #expect(state.sessions.map(\.id) == ["s1", "s2"])
  }

  @Test("a stale state event is ignored without touching lastRev")
  func staleIgnored() {
    var state = connectedState(rev: 41)
    let old = makeSession(title: "Old title")
    let outcome = MenuStateReducer.apply(&state, EventFrame(event: .session(old), rev: 40))
    #expect(outcome == .ignoredStale)
    #expect(state.sessions.map(\.title) == ["Weekly sync"])
    #expect(state.lastRev == 41)
  }

  @Test("a rev gap demands resubscription and applies nothing")
  func gapDetected() {
    var state = connectedState(rev: 41)
    let outcome = MenuStateReducer.apply(
      &state, EventFrame(event: .session(makeSession()), rev: 43))
    #expect(outcome == .gap)
    #expect(state.lastRev == 41)
  }

  @Test("a source event updates the matching source's runtime state")
  func sourceEventApplies() {
    var state = connectedState(rev: 41)
    state.sources = [SourceStatus(id: SourceID("mic"), state: .capturing, codec: "opus")]
    let outcome = MenuStateReducer.apply(
      &state, EventFrame(event: .source(id: SourceID("mic"), state: .paused), rev: 42))
    #expect(outcome == .applied)
    #expect(state.sources.first?.state == .paused)
  }

  @Test("job telemetry upserts by id, never touches lastRev, and done removes the job")
  func jobLifecycle() {
    var state = connectedState(rev: 41)
    let started = JobPublishParams(
      job: "cleanup-1", kind: "cleanup", session: "s1", state: .started)
    #expect(MenuStateReducer.apply(&state, EventFrame(event: .job(started))) == .applied)
    #expect(state.jobs.map(\.job) == ["cleanup-1"])
    #expect(state.lastRev == 41)

    let done = JobPublishParams(job: "cleanup-1", kind: "cleanup", session: "s1", state: .done)
    #expect(MenuStateReducer.apply(&state, EventFrame(event: .job(done))) == .applied)
    #expect(state.jobs.isEmpty)
  }

  @Test("a failed job is retained until dismissed")
  func failedJobRetainedUntilDismissed() {
    var state = connectedState(rev: 41)
    let failed = JobPublishParams(job: "sum-1", kind: "summarize", session: "s1", state: .failed)
    _ = MenuStateReducer.apply(&state, EventFrame(event: .job(failed)))
    #expect(state.failedJobs.map(\.job) == ["sum-1"])
    MenuStateReducer.dismissJob(&state, id: "sum-1")
    #expect(state.jobs.isEmpty)
  }

  @Test("vad and segment telemetry are no-op applied")
  func otherTelemetryIgnored() {
    var state = connectedState(rev: 41)
    let outcome = MenuStateReducer.apply(
      &state,
      EventFrame(event: .vad(source: SourceID("mic"), state: .speech, t: instant(1_005))))
    #expect(outcome == .applied)
    #expect(state.lastRev == 41)
  }

  @Test("a state event with no rev while connected returns gap and mutates nothing")
  func missingRevWhileConnected() {
    var state = connectedState(rev: 41)
    let session = makeSession(title: "Should not apply")
    let outcome = MenuStateReducer.apply(
      &state, EventFrame(event: .session(session), rev: nil))
    #expect(outcome == .gap)
    #expect(state.sessions.map(\.title) == ["Weekly sync"])
    #expect(state.lastRev == 41)
  }

  @Test("a state event applied to a never-connected state returns gap and mutates nothing")
  func stateEventBeforeSnapshot() {
    var state = MenuState()
    let session = makeSession(title: "Should not apply")
    let outcome = MenuStateReducer.apply(
      &state, EventFrame(event: .session(session), rev: 1))
    #expect(outcome == .gap)
    #expect(state.sessions.isEmpty)
    #expect(state.lastRev == nil)
  }

  @Test("meeting.activity telemetry upserts by source and applies without a rev")
  func meetingActivityUpserts() {
    var state = MenuState()
    state.connection = .connected
    state.lastRev = 1
    let began = MeetingActivityStatus(
      source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
      label: "Zoom", active: true, episode: "us.zoom.xos#1")
    #expect(MenuStateReducer.apply(&state, EventFrame(event: .meetingActivity(began))) == .applied)
    #expect(state.activeMeetings == [began])
    var ended = began
    ended.active = false
    _ = MenuStateReducer.apply(&state, EventFrame(event: .meetingActivity(ended)))
    #expect(state.activeMeetings.isEmpty)
    #expect(state.meetingActivity == [ended])
  }

  @Test("reconnect clears stale activity until status catches up")
  func reconnectClearsActivity() {
    var state = MenuState()
    state.meetingActivity = [
      MeetingActivityStatus(
        source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
        label: "Zoom", active: true, episode: "us.zoom.xos#1")
    ]
    MenuStateReducer.connected(
      &state, daemon: "earsd", snapshot: SnapshotData(rev: 0, sessions: [], sources: []))
    #expect(state.meetingActivity.isEmpty)
    MenuStateReducer.catchUpMeetingActivity(
      &state,
      [
        MeetingActivityStatus(
          source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
          label: "Zoom", active: true, episode: "us.zoom.xos#2")
      ], ifEditsEqual: state.meetingActivityEdits)
    #expect(state.activeMeetings.count == 1)
  }

  @Test("a catch-up issued before a reconnect never lands on the reconnected state")
  func catchUpFromBeforeAReconnectIsDiscarded() {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd", snapshot: SnapshotData(rev: 0, sessions: [], sources: []))
    // The mark the first connection's catch-up captured before asking `status`.
    let mark = state.meetingActivityEdits
    // The socket dropped and redialled before that answer arrived.
    MenuStateReducer.connected(
      &state, daemon: "earsd", snapshot: SnapshotData(rev: 0, sessions: [], sources: []))
    MenuStateReducer.catchUpMeetingActivity(
      &state,
      [
        MeetingActivityStatus(
          source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
          label: "Zoom", active: true, episode: "us.zoom.xos#1")
      ], ifEditsEqual: mark)
    #expect(state.meetingActivity.isEmpty)
  }

  @Test("a live edge that lands while a status catch-up is in flight wins over it")
  func liveEdgeDuringCatchUpWins() {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd", snapshot: SnapshotData(rev: 0, sessions: [], sources: []))
    // The mark a caller would capture right before asking the daemon for `status`.
    let mark = state.meetingActivityEdits
    let ended = MeetingActivityStatus(
      source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
      label: "Zoom", active: false, episode: "us.zoom.xos#1")
    _ = MenuStateReducer.apply(&state, EventFrame(event: .meetingActivity(ended)))

    // The catch-up's answer arrives after the live edge — it's stale, so it
    // must not clobber the edge it raced.
    MenuStateReducer.catchUpMeetingActivity(
      &state,
      [
        MeetingActivityStatus(
          source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
          label: "Zoom", active: true, episode: "us.zoom.xos#1")
      ], ifEditsEqual: mark)
    #expect(state.meetingActivity == [ended])

    // A catch-up whose mark matches the current count applies normally.
    let freshMark = state.meetingActivityEdits
    MenuStateReducer.catchUpMeetingActivity(
      &state,
      [
        MeetingActivityStatus(
          source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos",
          label: "Zoom", active: true, episode: "us.zoom.xos#2")
      ], ifEditsEqual: freshMark)
    #expect(state.activeMeetings.count == 1)
  }
}
