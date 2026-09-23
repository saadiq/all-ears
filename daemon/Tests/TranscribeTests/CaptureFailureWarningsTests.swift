import EarsCore
import EarsDataStore
import Foundation
import Testing

@testable import transcribe

@Suite("Capture-failure warnings")
struct CaptureFailureWarningsTests {
  private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("capture-failures-\(UUID().uuidString)")
  }

  private func append(_ entry: SessionEventLog.Entry, root: URL) throws {
    try SessionEventLog.append(entry, dataRoot: root, sessionID: "s1")
  }

  @Test("each capture_failed event becomes one warning naming the source and reason")
  func captureFailedEventsBecomeWarnings() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try append(.init(t: "2026-09-23T12:30:05Z", event: "started"), root: root)
    try append(
      .init(
        t: "2026-09-23T12:30:08Z", event: "capture_failed",
        source: "app:com.microsoft.teams2", reason: "tap build failed"),
      root: root)
    try append(.init(t: "2026-09-23T13:03:10Z", event: "ended", reason: "app-idle"), root: root)

    let warnings = TranscribePipeline.captureFailureWarnings(sessionID: "s1", dataRoot: root)
    #expect(
      warnings == [
        "source 'app:com.microsoft.teams2' failed to capture (tap build failed); "
          + "its audio is missing from this transcript"
      ])
  }

  @Test("a repeated identical failure is reported once")
  func repeatedFailureIsDeduplicated() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for t in ["2026-09-23T12:30:08Z", "2026-09-23T12:40:08Z"] {
      try append(
        .init(t: t, event: "capture_failed", source: "browser:meet:t3", reason: "decoder gave up"),
        root: root)
    }

    let warnings = TranscribePipeline.captureFailureWarnings(sessionID: "s1", dataRoot: root)
    #expect(warnings.count == 1)
  }

  @Test("no session, or a session with no events.jsonl, yields no warnings")
  func noSessionNoWarnings() {
    let root = makeRoot()
    #expect(TranscribePipeline.captureFailureWarnings(sessionID: nil, dataRoot: root).isEmpty)
    #expect(TranscribePipeline.captureFailureWarnings(sessionID: "s1", dataRoot: root).isEmpty)
  }
}
