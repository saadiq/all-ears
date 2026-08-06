import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("SessionArtifactLocator")
struct SessionArtifactLocatorTests {
  func endedSession(id: String = "0d5e7f6a") -> Session {
    // 2026-07-17T10:30:00Z == 1_784_284_200 — verified with
    // `TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "2026-07-17T10:30:00Z" +%s`
    let start = instant(1_784_284_200)
    return Session(
      id: id, title: "standup", state: .ended, started: start,
      ended: start.advanced(by: 600),
      intervals: [SessionInterval(start: start, end: start.advanced(by: 600))])
  }

  @Test("the key mirrors transcribe's day directory and time_slug prefix")
  func keyMatchesTranscribeLayout() {
    let key = SessionArtifactLocator.key(for: endedSession())
    #expect(key == SessionArtifactKey(day: "2026-07-17", filePrefix: "10-30-00_0d5e7f6a"))
  }

  @Test("a session with no non-empty interval has no key")
  func emptyIntervalsNoKey() {
    var session = endedSession()
    session.intervals = []
    #expect(SessionArtifactLocator.key(for: session) == nil)
  }

  @Test("classify picks transcript, clean, and every summary; ignores sidecars and strangers")
  func classifyFilenames() {
    let key = SessionArtifactKey(day: "2026-07-17", filePrefix: "10-30-00_0d5e7f6a")
    let artifacts = SessionArtifactLocator.classify(
      filenames: [
        "10-30-00_0d5e7f6a.transcript.md",
        "10-30-00_0d5e7f6a.transcript.json",
        "10-30-00_0d5e7f6a.clean.md",
        "10-30-00_0d5e7f6a.brief.summary.md",
        "10-30-00_0d5e7f6a.decisions.summary.md",
        "10-30-00_0d5e7f6a.summary.json",
        "09-00-00_other.transcript.md",
      ],
      key: key)
    #expect(artifacts.transcript == "10-30-00_0d5e7f6a.transcript.md")
    #expect(artifacts.clean == "10-30-00_0d5e7f6a.clean.md")
    #expect(
      artifacts.summaries == [
        "10-30-00_0d5e7f6a.brief.summary.md", "10-30-00_0d5e7f6a.decisions.summary.md",
      ])
  }
}

@Suite("RecentSessions")
struct RecentSessionsTests {
  @Test("select keeps ended sessions, newest first, capped")
  func selectsEndedNewestFirst() {
    let sessions = [
      makeSession(id: "live", state: .active, started: 5_000),
      makeSession(id: "old", state: .ended, started: 1_000),
      makeSession(id: "new", state: .ended, started: 3_000),
      makeSession(id: "mid", state: .ended, started: 2_000),
    ]
    #expect(RecentSessions.select(from: sessions, limit: 2).map(\.id) == ["new", "mid"])
  }
}
