import EarsConfig
import EarsCore
import EarsDataStore
import Foundation

/// The config-derived facts a disk scan needs: where the data root is, and
/// how `cleanup` resolves its published path. One `loadConfig` pass, shared
/// by every session the command scans.
struct ScanEnvironment {
  var dataRoot: URL
  var cleanupTemplate: PathTemplate
  var outputRoot: String
  var weekNumbering: WeekNumbering
}

/// Assembles a ``SessionArtifacts`` for one session by reading what is on
/// disk — the I/O half of the pipeline reconstruction, feeding
/// ``SessionPipeline``'s pure derivation. Everything is best-effort reads: a
/// missing or unparseable artifact leaves its fields at their defaults, and
/// the derivation renders the absence rather than this scanner failing.
enum SessionArtifactScanner {
  /// Resolves the scan environment from the same layered config every tool
  /// reads. `[cleanup] output`, `output_root`, and `week_numbering` mirror
  /// exactly what `CleanupRuntime` resolves, so the reconstructed published
  /// path can only agree with the writer's.
  static func environment(configFlag: String?) -> Result<ScanEnvironment, ConfigResolutionError> {
    let inputs = ConfigLoadInputs(
      configFlag: configFlag,
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    switch loadConfig(inputs) {
    case .failure(let error):
      return .failure(ConfigResolutionError(description: "error: could not load config: \(error)"))
    case .success(let loaded):
      let dataRoot = stringValue(loaded.value, ["data_root"])
      let template = stringValue(loaded.value, ["cleanup", "output"])
      return .success(
        ScanEnvironment(
          dataRoot: URL(fileURLWithPath: dataRoot.isEmpty ? "." : dataRoot),
          cleanupTemplate: PathTemplate(
            template.isEmpty ? LLMStagesConfigSchema.defaultCleanupOutput : template),
          outputRoot: stringValue(loaded.value, ["output_root"]),
          weekNumbering: WeekNumbering(configValue: stringValue(loaded.value, ["week_numbering"]))))
    }
  }

  static func scan(session: Session, environment: ScanEnvironment) -> SessionArtifacts {
    var artifacts = SessionArtifacts()
    scanCapture(session: session, environment: environment, into: &artifacts)
    scanAttribution(session: session, environment: environment, into: &artifacts)
    scanTranscriptChain(session: session, environment: environment, into: &artifacts)
    return artifacts
  }

  // MARK: - Per-area scans

  private static func scanCapture(
    session: Session, environment: ScanEnvironment, into artifacts: inout SessionArtifacts
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
    session: Session, environment: ScanEnvironment, into artifacts: inout SessionArtifacts
  ) {
    let url = SessionAttributionLog.fileURL(
      dataRoot: environment.dataRoot, sessionID: session.id)
    guard let jsonl = try? String(contentsOf: url, encoding: .utf8) else { return }
    artifacts.hasAttributionLog = true
    artifacts.speechCaptures = AttributionBindingHints.speechEvidence(jsonl: jsonl).speechCaptures
  }

  private static func scanTranscriptChain(
    session: Session, environment: ScanEnvironment, into artifacts: inout SessionArtifacts
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

    // Where cleanup published (or will publish): the same template context
    // the stage itself expands, off this document's own frontmatter.
    let cleanupPath = environment.cleanupTemplate.expand(
      CleanupPublishedPath.context(
        outputRoot: environment.outputRoot,
        weekNumbering: environment.weekNumbering,
        frontmatter: document.frontmatter,
        transcriptPath: transcriptURL.path))
    artifacts.cleanupPath = cleanupPath

    let cleanupURL = URL(fileURLWithPath: cleanupPath)
    guard let cleanMarkdown = try? String(contentsOf: cleanupURL, encoding: .utf8) else { return }
    artifacts.cleanupExists = true
    if let clean = try? TranscriptParser.parse(
      markdown: cleanMarkdown, jsonSidecar: sidecarText(for: cleanupURL))
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
      artifacts.summaryCount =
        names.filter { $0.hasPrefix(stem) && $0.hasSuffix(".summary.md") }.count
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

  private static func stringValue(_ config: ConfigValue, _ path: [String]) -> String {
    var current = config
    for key in path {
      guard case .table(let table) = current, let next = table[key] else { return "" }
      current = next
    }
    guard case .string(let value) = current else { return "" }
    return value
  }
}
