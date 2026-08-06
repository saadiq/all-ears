import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("NotificationPolicy")
struct NotificationPolicyTests {
  func stateWithEndedSession() -> MenuState {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0",
      snapshot: makeSnapshot(rev: 41, sessions: [makeSession(state: .ended)]))
    return state
  }

  @Test("summarize done notifies summary-ready with an open action")
  func summarizeDoneNotifies() {
    let frame = EventFrame(
      event: .job(JobPublishParams(job: "sum-1", kind: "summarize", session: "s1", state: .done)))
    let request = NotificationPolicy.onEvent(frame, state: stateWithEndedSession())
    #expect(
      request
        == NotificationRequest(
          title: "Summary ready", body: "Weekly sync", action: .openSummary(session: "s1")))
  }

  @Test("any failed stage notifies with a reveal action")
  func failureNotifies() {
    let frame = EventFrame(
      event: .job(JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: .failed)))
    let request = NotificationPolicy.onEvent(frame, state: stateWithEndedSession())
    #expect(
      request
        == NotificationRequest(
          title: "Transcription failed", body: "Weekly sync", action: .revealSession(session: "s1"))
    )
  }

  @Test("the quiet cases stay quiet")
  func quietCases() {
    let state = stateWithEndedSession()
    let quiet: [EarsEvent] = [
      .job(JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: .started)),
      .job(JobPublishParams(job: "t-1", kind: "transcribe", session: "s1", state: .done)),
      .job(JobPublishParams(job: "c-1", kind: "cleanup", session: "s1", state: .done)),
      .session(makeSession()),
      .source(id: SourceID("mic"), state: .paused),
    ]
    for event in quiet {
      #expect(NotificationPolicy.onEvent(EventFrame(event: event, rev: 42), state: state) == nil)
    }
  }

  @Test("disconnect during an active session warns; while idle it does not")
  func disconnectPolicy() {
    var recording = MenuState()
    MenuStateReducer.connected(
      &recording, daemon: "earsd 0.1.0",
      snapshot: makeSnapshot(rev: 41, sessions: [makeSession()]))
    #expect(
      NotificationPolicy.onDisconnect(state: recording)
        == NotificationRequest(
          title: "Recording at risk",
          body: "earsd stopped while ‘Weekly sync’ was recording.", action: .none))
    #expect(NotificationPolicy.onDisconnect(state: stateWithEndedSession()) == nil)
  }

  @Test("repeated disconnects on the same drop stay quiet; a reconnect re-arms the warning")
  func disconnectIsEdgeTriggered() {
    var state = MenuState()
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0",
      snapshot: makeSnapshot(rev: 41, sessions: [makeSession()]))

    // First drop while connected: warns.
    #expect(
      NotificationPolicy.onDisconnect(state: state)
        == NotificationRequest(
          title: "Recording at risk",
          body: "earsd stopped while ‘Weekly sync’ was recording.", action: .none))
    MenuStateReducer.disconnected(&state)

    // Subsequent redial failures while already unreachable: quiet.
    #expect(NotificationPolicy.onDisconnect(state: state) == nil)
    #expect(NotificationPolicy.onDisconnect(state: state) == nil)

    // Reconnect, then drop again: warns again.
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0",
      snapshot: makeSnapshot(rev: 41, sessions: [makeSession()]))
    #expect(
      NotificationPolicy.onDisconnect(state: state)
        == NotificationRequest(
          title: "Recording at risk",
          body: "earsd stopped while ‘Weekly sync’ was recording.", action: .none))
  }

  @Test("a crash-looping daemon warns once per session, not once per crash")
  func atRiskWarningIsPerSession() {
    var state = MenuState()
    var warned: Set<String> = []
    let session = makeSession()

    // Each crash/reconnect cycle re-arms the edge, so the edge alone is not
    // enough: without per-session dedup this banners every second forever.
    for _ in 0..<3 {
      MenuStateReducer.connected(
        &state, daemon: "earsd 0.1.0", snapshot: makeSnapshot(rev: 41, sessions: [session]))
      if NotificationPolicy.onDisconnect(state: state, warnedSessions: warned) != nil {
        warned.insert(session.id)
      }
      MenuStateReducer.disconnected(&state)
    }
    #expect(warned == [session.id])

    // A different session at risk is news again.
    let next = makeSession(id: "s2", title: "Standup")
    MenuStateReducer.connected(
      &state, daemon: "earsd 0.1.0", snapshot: makeSnapshot(rev: 41, sessions: [next]))
    #expect(
      NotificationPolicy.onDisconnect(state: state, warnedSessions: warned)
        == NotificationRequest(
          title: "Recording at risk",
          body: "earsd stopped while ‘Standup’ was recording.", action: .none))
  }

  @Test("failed job with unknown session id shows first 8 chars as title")
  func failureWithUnknownSessionId() {
    let frame = EventFrame(
      event: .job(
        JobPublishParams(
          job: "t-1", kind: "transcribe", session: "deadbeef-1234", state: .failed)))
    let request = NotificationPolicy.onEvent(frame, state: stateWithEndedSession())
    #expect(
      request
        == NotificationRequest(
          title: "Transcription failed", body: "deadbeef",
          action: .revealSession(session: "deadbeef-1234"))
    )
  }

  @Test("failed job with nil session id shows generic body and action")
  func failureWithNilSessionId() {
    let frame = EventFrame(
      event: .job(JobPublishParams(job: "t-1", kind: "transcribe", session: nil, state: .failed)))
    let request = NotificationPolicy.onEvent(frame, state: stateWithEndedSession())
    #expect(
      request
        == NotificationRequest(
          title: "Transcription failed", body: "session", action: .none)
    )
  }
}
