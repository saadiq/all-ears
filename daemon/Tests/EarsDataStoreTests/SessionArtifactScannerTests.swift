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

  @Test("the outcome depth skips the capture walk and attribution but reads the transcript chain")
  func outcomeDepthIsLighter() throws {
    let (environment, session, _) = try Self.makeStore()
    defer { try? FileManager.default.removeItem(at: environment.dataRoot) }
    let sources = DataStoreLayout.sessionDirectory(
      dataRoot: environment.dataRoot, sessionID: session.id
    ).appendingPathComponent("sources/mic")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 64).write(to: sources.appendingPathComponent("chunk"))

    let full = SessionArtifactScanner.scan(session: session, environment: environment)
    let light = SessionArtifactScanner.scan(
      session: session, environment: environment, depth: .outcome)

    #expect(!full.captureBytesBySource.isEmpty)
    #expect(light.captureBytesBySource.isEmpty)
    #expect(light.transcriptExists && light.cleanupExists)
    #expect(light.summaryPaths == full.summaryPaths)
  }

  @Test("a damaged body or sidecar still resolves the published tier from the frontmatter")
  func frontmatterAloneResolvesThePublishedTier() throws {
    let (environment, session, published) = try Self.makeStore()
    defer { try? FileManager.default.removeItem(at: environment.dataRoot) }
    let transcript = DataStoreLayout.sessionTranscriptFile(
      dataRoot: environment.dataRoot, sessionID: session.id)
    // A sidecar that will not decode makes the raw transcript's full parse
    // throw; a vault-reflowed body does the same for the cleaned copy.
    try Data("not json".utf8).write(
      to: transcript.deletingPathExtension().appendingPathExtension("json"))
    let reflowed = EmptySessionTranscripts.substantive
      .replacingOccurrences(
        of: "kind: transcript\n", with: "kind: transcript\nnote: \"[[notes]]\"\n"
      )
      .replacingOccurrences(of: "**[09:15:04] You**", with: "a reflowed paragraph")
    try Data(reflowed.utf8).write(to: published.appendingPathComponent("notes.md"))
    #expect(throws: (any Error).self) {
      try TranscriptParser.parse(markdown: reflowed)
    }

    let artifacts = SessionArtifactScanner.scan(
      session: session, environment: environment, depth: .outcome)

    #expect(artifacts.transcriptWords == 214)
    #expect(artifacts.cleanupExists)
    #expect(artifacts.noteLink == "[[notes]]")
    #expect(artifacts.summaryCount == 2)
  }

  @Test("a preset's own `out` is listed ahead of the siblings when it exists")
  func explicitPresetOutputs() throws {
    var (environment, session, published) = try Self.makeStore()
    defer { try? FileManager.default.removeItem(at: environment.dataRoot) }
    let vault = environment.dataRoot.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    let daily = vault.appendingPathComponent("4a1f9c22-0d18-4a71-9f0b-2c4e6d8a1b33.md")
    try Data("x".utf8).write(to: daily)
    environment.summaryOutputs = [
      PathTemplate(vault.path + "/{session}.md"),
      // Configured, but never written: not offered.
      PathTemplate(vault.path + "/missing.md"),
      // Already a sibling: listed once.
      PathTemplate(published.path + "/notes.summary.md"),
    ]

    let artifacts = SessionArtifactScanner.scan(
      session: session, environment: environment, depth: .outcome)

    #expect(
      artifacts.summaryPaths == [
        daily.path,
        published.appendingPathComponent("notes.summary.md").path,
        published.appendingPathComponent("notes.brief.summary.md").path,
      ])
    #expect(artifacts.summaryCount == 3)
  }

  @Test("summary outputs resolve from each preset's `out`, `{notes}` through its `notes`")
  func resolvesPresetOutputs() {
    func preset(_ fields: [String: String]) -> ConfigValue {
      .table(fields.mapValues { .string($0) })
    }
    let config = ConfigValue.table([
      "summarize": .table([
        "preset": .array([
          preset(["name": "plain"]),
          preset(["name": "filed", "out": "/vault/{date}.md"]),
          preset(["name": "daily", "notes": "/vault/daily/{date}.md", "out": "{notes}"]),
          // `{notes}` with no `notes` names no file at all.
          preset(["name": "broken", "out": "{notes}"]),
        ])
      ])
    ])

    let environment = SessionScanEnvironment.resolve(from: config)

    #expect(
      environment.summaryOutputs.map(\.raw) == ["/vault/{date}.md", "/vault/daily/{date}.md"])
  }
}
