import Foundation
import Testing

@testable import EarsCore

@Suite("SessionsListRendering")
struct SessionsListRenderingTests {
  private let utc = TimeZone(identifier: "UTC")!
  /// 2026-08-17T15:01:00Z.
  private let matt = Instant(secondsSinceEpoch: 1_786_978_860)
  private var now: Instant { matt.advanced(by: 4 * 3_600) }

  private func session(
    id: String, title: String, started: Instant, state: SessionState = .ended,
    warnings: [String] = []
  ) -> Session {
    Session(
      id: id, title: title, state: state, started: started,
      ended: state == .ended ? started.advanced(by: 1_800) : nil, warnings: warnings)
  }

  private func published() -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    artifacts.noteLink = "[[calls/x]]"
    return artifacts
  }

  @Test("sessions group under TODAY/YESTERDAY/date, newest first, with outcomes")
  func groupsByLocalDay() {
    let entries = [
      SessionListEntry(
        session: session(
          id: "a", title: "Weekly Product Meeting", started: matt.advanced(by: 3 * 3_600),
          state: .active),
        artifacts: SessionArtifacts()),
      SessionListEntry(
        session: session(id: "b", title: "Matt Silva", started: matt, warnings: ["w1", "w2"]),
        artifacts: published()),
      SessionListEntry(
        session: session(id: "c", title: "Stefni Bridges", started: matt.advanced(by: -86_400)),
        artifacts: published()),
      SessionListEntry(
        session: session(
          id: "d", title: "Kickoff", started: matt.advanced(by: -3 * 86_400)),
        artifacts: SessionArtifacts()),
    ]
    let text = SessionsListRendering.render(
      entries: entries, now: now, timeZone: utc)
    #expect(
      text == """
        TODAY
          18:01  Weekly Product Meeting  ● recording (1h)
          15:01  Matt Silva              ⚠ published, 2 warnings
        YESTERDAY
          15:01  Stefni Bridges          ✓ published
        2026-08-14
          15:01  Kickoff                 – no transcript
        """)
  }

  @Test("an empty list says so")
  func emptyList() {
    #expect(
      SessionsListRendering.render(entries: [], now: now, timeZone: utc) == "(no sessions)")
  }
}
