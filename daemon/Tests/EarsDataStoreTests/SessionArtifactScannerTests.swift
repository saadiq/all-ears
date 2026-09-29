import EarsCore
import EarsCoreTestSupport
import Foundation
import Testing

@testable import EarsDataStore

@Suite("SessionArtifactScanner")
struct SessionArtifactScannerTests {
  /// A store with one ended session whose transcript parses, a published
  /// clean transcript at a fixed template path, and two summaries beside it.
  private static func makeStore() throws -> (SessionScanEnvironment, Session, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("scanner-\(UUID().uuidString)")
    let published = root.appendingPathComponent("published")
    try FileManager.default.createDirectory(at: published, withIntermediateDirectories: true)
    let session = Session(
      id: "c08595c8-77fa-48c4-a077-ff5d9f60e522", title: "call", state: .ended,
      started: Instant(secondsSinceEpoch: 1_000), ended: Instant(secondsSinceEpoch: 2_000),
      sources: ["mic"])
    let transcript = DataStoreLayout.sessionTranscriptFile(dataRoot: root, sessionID: session.id)
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(EmptySessionTranscripts.substantive.utf8).write(to: transcript)
    for name in ["notes.md", "notes.summary.md", "notes.brief.summary.md"] {
      try Data("x".utf8).write(to: published.appendingPathComponent(name))
    }
    let environment = SessionScanEnvironment(
      dataRoot: root, cleanupTemplate: PathTemplate(published.path + "/notes.md"),
      outputRoot: published.path, weekNumbering: .us, onEndChain: OnEndStage.allCases)
    return (environment, session, published)
  }

  @Test("summary paths are the published summaries beside the clean transcript, sorted")
  func reportsSummaryPaths() throws {
    let (environment, session, published) = try Self.makeStore()
    defer { try? FileManager.default.removeItem(at: environment.dataRoot) }

    let artifacts = SessionArtifactScanner.scan(session: session, environment: environment)

    #expect(artifacts.cleanupExists)
    #expect(
      artifacts.summaryPaths == [
        published.appendingPathComponent("notes.brief.summary.md").path,
        published.appendingPathComponent("notes.summary.md").path,
      ])
    #expect(artifacts.summaryCount == 2)
  }
}
