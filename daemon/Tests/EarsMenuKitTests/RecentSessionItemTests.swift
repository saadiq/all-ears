import EarsCore
import Foundation
import Testing

@testable import EarsMenuKit

@Suite("RecentSessionItem")
struct RecentSessionItemTests {
  private let session = Session(
    id: "s1", title: "call", state: .ended, started: Instant(secondsSinceEpoch: 0),
    ended: Instant(secondsSinceEpoch: 60))

  @Test("paths come from what the scan found on disk; an absent clean copy is nil")
  func mapsArtifacts() {
    var artifacts = SessionArtifacts()
    artifacts.transcriptExists = true
    artifacts.transcriptPath = "/d/sessions/s1/transcript.md"
    artifacts.cleanupPath = "/p/call.md"
    artifacts.cleanupExists = false
    artifacts.summaryPaths = ["/p/call.summary.md"]
    let item = RecentSessionItem(
      session: session, artifacts: artifacts, outcome: PipelineOutcome(glyph: "·", text: "x"))
    #expect(item.transcript == URL(fileURLWithPath: "/d/sessions/s1/transcript.md"))
    #expect(item.clean == nil)
    #expect(item.summaries == [URL(fileURLWithPath: "/p/call.summary.md")])
    #expect(item.id == "s1")
  }

  @Test("recent sessions are ended ones, most recently ended first")
  func selectsByEnd() {
    let long = Session(
      id: "long", title: "l", state: .ended, started: Instant(secondsSinceEpoch: 0),
      ended: Instant(secondsSinceEpoch: 500))
    let short = Session(
      id: "short", title: "s", state: .ended, started: Instant(secondsSinceEpoch: 100),
      ended: Instant(secondsSinceEpoch: 200))
    let live = Session(
      id: "live", title: "v", state: .active, started: Instant(secondsSinceEpoch: 600))
    #expect(RecentSessions.select(from: [short, live, long]).map(\.id) == ["long", "short"])
  }
}
