import EarsCore
import Foundation

/// Assembles a ``SessionArtifacts`` for one session by reading what is on
/// disk — the I/O half of the pipeline reconstruction, feeding
/// ``SessionPipeline``'s pure derivation. Everything is best-effort reads: a
/// missing or unparseable artifact leaves its fields at their defaults, and
/// the derivation renders the absence rather than this scanner failing.
///
/// The one implementation every read-only surface uses, so they agree on
/// where a session's transcript, cleaned copy and summaries are.
public enum SessionArtifactScanner {
  public static func scan(
    session: Session, environment: SessionScanEnvironment
  ) -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    scanCapture(session: session, environment: environment, into: &artifacts)
    scanAttribution(session: session, environment: environment, into: &artifacts)
    scanTranscriptChain(session: session, environment: environment, into: &artifacts)
    return artifacts
  }

  // MARK: - Per-area scans

  private static func scanCapture(
    session: Session, environment: SessionScanEnvironment, into artifacts: inout SessionArtifacts
  ) {
    let sourcesDirectory = DataStoreLayout.sessionDirectory(
      dataRoot: environment.dataRoot, sessionID: session.id
    ).appendingPathComponent("sources")
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: sourcesDirectory, includingPropertiesForKeys: [.isDirectoryKey])
    else { return }
    // Directory names are the path-safe id form; recover the natural id from
    // the session record where it names the source, and fall back to the
    // directory name (still an opaque handle, never parsed for identity).
    let byPathSafe = Dictionary(
      session.sources.map { ($0.pathSafe, $0) }, uniquingKeysWith: { first, _ in first })
    for entry in entries {
      guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
        continue
      }
      let id = byPathSafe[entry.lastPathComponent] ?? SourceID(entry.lastPathComponent)
      artifacts.captureBytesBySource[id] = directorySize(entry)
    }
  }

  private static func scanAttribution(
    session: Session, environment: SessionScanEnvironment, into artifacts: inout SessionArtifacts
  ) {
    let url = SessionAttributionLog.fileURL(
      dataRoot: environment.dataRoot, sessionID: session.id)
    guard let jsonl = try? String(contentsOf: url, encoding: .utf8) else { return }
    artifacts.hasAttributionLog = true
    artifacts.speechCaptures = AttributionBindingHints.speechEvidence(jsonl: jsonl).speechCaptures
  }

  private static func scanTranscriptChain(
    session: Session, environment: SessionScanEnvironment, into artifacts: inout SessionArtifacts
  ) {
    let transcriptURL = DataStoreLayout.sessionTranscriptFile(
      dataRoot: environment.dataRoot, sessionID: session.id)
    guard let markdown = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return }
    artifacts.transcriptExists = true
    artifacts.transcriptPath = transcriptURL.path
    guard
      let document = try? TranscriptParser.parse(
        markdown: markdown, jsonSidecar: sidecarText(for: transcriptURL))
    else { return }
    artifacts.transcriptSegments = document.segments.count
    artifacts.transcriptWords = document.frontmatter.wordCount
    artifacts.transcriptSpeechSeconds = document.frontmatter.speechSeconds

    // Where cleanup published (or will publish): the same template context
    // the stage itself expands, off this document's own frontmatter.
    let cleanupPath = environment.cleanupTemplate.expand(
      CleanupPublishedPath.context(
        outputRoot: environment.outputRoot,
        weekNumbering: environment.weekNumbering,
        frontmatter: document.frontmatter,
        transcriptPath: transcriptURL.path))
    artifacts.cleanupPath = cleanupPath

    // The published copy lives in the user's vault, where other tooling may
    // have reformatted the frontmatter — TranscriptParser reads any valid
    // YAML style, so the vault-linted shape parses like our own.
    let cleanupURL = URL(fileURLWithPath: cleanupPath)
    guard let cleanMarkdown = try? String(contentsOf: cleanupURL, encoding: .utf8) else { return }
    artifacts.cleanupExists = true
    // The cleaned sidecar stays in the data store beside the input transcript
    // (CleanupPublishedPath.cleanSidecarURL) — only the Markdown publishes.
    let cleanSidecar = try? String(
      contentsOf: CleanupPublishedPath.cleanSidecarURL(forInput: transcriptURL),
      encoding: .utf8)
    if let clean = try? TranscriptParser.parse(
      markdown: cleanMarkdown, jsonSidecar: cleanSidecar)
    {
      artifacts.cleanupSegments = clean.segments.count
      artifacts.noteLink = clean.frontmatter.note
    }

    // Summaries land as `<stem>.summary.md` / `<stem>.<preset>.summary.md`
    // siblings of the cleaned transcript (SummarizePipeline's default
    // naming); presets that publish elsewhere surface through `note:` above.
    let stem = CleanupPublishedPath.documentStem(cleanupURL)
    let directory = cleanupURL.deletingLastPathComponent()
    if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
      artifacts.summaryCount = SummarySiblings.select(filenames: names, stem: stem).count
    }
  }

  // MARK: - Small helpers

  private static func sidecarText(for markdownURL: URL) -> String? {
    try? String(
      contentsOf: markdownURL.deletingPathExtension().appendingPathExtension("json"),
      encoding: .utf8)
  }

  private static func directorySize(_ directory: URL) -> Int {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.fileSizeKey])
    else { return 0 }
    var total = 0
    for case let url as URL in enumerator {
      total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
    return total
  }
}
