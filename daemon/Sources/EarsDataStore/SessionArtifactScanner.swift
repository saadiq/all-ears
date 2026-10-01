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
  /// How much of a session to read.
  public enum Depth: Sendable {
    /// Everything `ears session show` renders, including a size walk of every
    /// source directory.
    case full
    /// Only what a one-line outcome reads — the transcript chain. List views
    /// scan many sessions per render, where the size walk is wasted.
    case outcome
  }

  public static func scan(
    session: Session, environment: SessionScanEnvironment, depth: Depth = .full
  ) -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    if depth == .full {
      scanCapture(session: session, environment: environment, into: &artifacts)
      scanAttribution(session: session, environment: environment, into: &artifacts)
    }
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
    // Frontmatter only for everything but the segment counts: the published
    // path, the gate's measurements and the `note:` link never read the body
    // or the JSON sidecar, and the full parse refuses a document whose body a
    // vault tool reflowed (or whose sidecar is damaged) even though the
    // frontmatter this needs is intact.
    guard let frontmatter = try? TranscriptParser.parseFrontmatter(markdown) else { return }
    artifacts.transcriptWords = frontmatter.wordCount
    artifacts.transcriptSpeechSeconds = frontmatter.speechSeconds
    if let document = try? TranscriptParser.parse(
      markdown: markdown, jsonSidecar: sidecarText(for: transcriptURL))
    {
      artifacts.transcriptSegments = document.segments.count
    }

    // Where cleanup published (or will publish): the same template context
    // the stage itself expands, off this document's own frontmatter.
    let context = CleanupPublishedPath.context(
      outputRoot: environment.outputRoot,
      weekNumbering: environment.weekNumbering,
      frontmatter: frontmatter,
      transcriptPath: transcriptURL.path)
    let cleanupPath = environment.cleanupTemplate.expand(context)
    artifacts.cleanupPath = cleanupPath
    let cleanupURL = URL(fileURLWithPath: cleanupPath)

    // The published copy lives in the user's vault, where other tooling may
    // have reformatted the frontmatter — TranscriptParser reads any valid
    // YAML style, so the vault-linted shape parses like our own.
    if let cleanMarkdown = try? String(contentsOf: cleanupURL, encoding: .utf8) {
      artifacts.cleanupExists = true
      artifacts.noteLink = (try? TranscriptParser.parseFrontmatter(cleanMarkdown))?.note
      // The cleaned sidecar stays in the data store beside the input
      // transcript (CleanupPublishedPath.cleanSidecarURL) — only the Markdown
      // publishes.
      let cleanSidecar = try? String(
        contentsOf: CleanupPublishedPath.cleanSidecarURL(forInput: transcriptURL),
        encoding: .utf8)
      if let clean = try? TranscriptParser.parse(
        markdown: cleanMarkdown, jsonSidecar: cleanSidecar)
      {
        artifacts.cleanupSegments = clean.segments.count
      }
    }

    // Summaries are looked up whether or not the cleaned copy is still where
    // cleanup put it: a summary the user filed elsewhere still opens.
    artifacts.summaryPaths = summaryPaths(
      environment: environment, context: context, cleanupURL: cleanupURL,
      noteLink: artifacts.noteLink)
    artifacts.summaryCount = artifacts.summaryPaths.count
  }

  /// Every summary on disk for this transcript. A preset that names its own
  /// `out` can write anywhere (an Obsidian daily note, say), so those are
  /// listed outright, first, followed by the file the cleaned copy's `note:`
  /// link names (where `summarize` actually wrote, even when it located a
  /// note the config alone cannot predict); the rest land as `<stem>.summary.md` /
  /// `<stem>.<preset>.summary.md` siblings of the cleaned transcript
  /// (SummarizePipeline's default naming) and are swept, so a summary written
  /// under a preset since renamed still opens. Each path appears once.
  private static func summaryPaths(
    environment: SessionScanEnvironment, context: PathTemplate.Context, cleanupURL: URL,
    noteLink: String?
  ) -> [String] {
    var seen = Set<String>()
    var paths: [String] = []
    func add(_ path: String) {
      let key = URL(fileURLWithPath: path).standardizedFileURL.path
      if seen.insert(key).inserted { paths.append(path) }
    }
    for template in environment.summaryOutputs {
      let path = template.expand(context)
      if isRegularFile(path) { add(path) }
    }
    if let noteLink, let path = VaultPath.resolve(noteLink: noteLink, near: cleanupURL.path),
      isRegularFile(path)
    {
      add(path)
    }
    let directory = cleanupURL.deletingLastPathComponent()
    if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
      let stem = CleanupPublishedPath.documentStem(cleanupURL)
      for name in SummarySiblings.select(filenames: names, stem: stem) {
        add(directory.appendingPathComponent(name).path)
      }
    }
    return paths
  }

  // MARK: - Small helpers

  private static func isRegularFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && !isDirectory.boolValue
  }

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
