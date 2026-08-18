import EarsCore
import EarsDataStore
import EarsMenuKit
import Foundation

/// One ended session plus the artifacts of its on-end chain that exist on
/// disk. `nil`/empty means the stage did not run, has not finished, or wrote
/// somewhere this build cannot resolve — the menu disables the verb rather
/// than offering a path that opens nothing.
struct RecentSessionItem: Identifiable, Hashable, Sendable {
  var session: Session
  /// The raw transcript in the data store — an intermediate, offered last.
  var transcript: URL?
  /// The published, cleaned transcript: the file you actually read.
  var clean: URL?
  var summaries: [URL]
  var id: String { session.id }
}

/// Read-only bridge from the on-disk stores to menu items. Never writes —
/// earsd stays the only writer.
struct RecentSessionsProvider: Sendable {
  var dataRoot: String
  var publishing: PublishingSettings

  func load(limit: Int = 7) -> [RecentSessionItem] {
    let all = SessionStore.readAll(dataRoot: URL(fileURLWithPath: dataRoot))
    return RecentSessions.select(from: all, limit: limit).map(item(for:))
  }

  /// The published tier is resolved from the raw transcript's own frontmatter
  /// — the context `cleanup` expanded — so no transcript on disk, or one that
  /// will not parse, leaves the published verbs disabled rather than pointing
  /// at a guessed path. That is the honest answer: `cleanup` consumes the
  /// transcript, and retention never sweeps it (it deletes `sources/` only), so
  /// a missing transcript means the chain never got that far.
  private func item(for session: Session) -> RecentSessionItem {
    let transcriptURL = SessionArtifactLocator.rawTranscript(
      dataRoot: dataRoot, sessionID: session.id)
    guard let document = parse(transcriptURL) else {
      return RecentSessionItem(
        session: session, transcript: existing(transcriptURL), clean: nil, summaries: [])
    }
    let paths = SessionArtifactLocator.published(
      frontmatter: document.frontmatter, transcriptPath: transcriptURL.path,
      settings: publishing)
    return RecentSessionItem(
      session: session,
      transcript: existing(transcriptURL),
      clean: existing(paths.clean),
      summaries: summaries(paths))
  }

  /// Best-effort: the sidecar carries structure the markdown alone does not,
  /// but a document without one still parses. Mirrors
  /// `ears`'s `SessionArtifactScanner.sidecarText`.
  private func parse(_ markdownURL: URL) -> TranscriptDocument? {
    guard let markdown = try? String(contentsOf: markdownURL, encoding: .utf8) else { return nil }
    let sidecar = try? String(
      contentsOf: markdownURL.deletingPathExtension().appendingPathExtension("json"),
      encoding: .utf8)
    return try? TranscriptParser.parse(markdown: markdown, jsonSidecar: sidecar)
  }

  /// A preset's own `out` is a path we can name outright; the rest are swept
  /// out of the published transcript's directory, so a summary written under
  /// a preset since renamed still opens.
  private func summaries(_ paths: PublishedArtifactPaths) -> [URL] {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: paths.summaryDirectory.path)) ?? []
    let siblings = SessionArtifactLocator.siblingSummaries(
      filenames: names, stem: paths.summaryStem
    ).map { paths.summaryDirectory.appendingPathComponent($0) }
    return paths.explicitSummaries.compactMap(existing) + siblings
  }

  private func existing(_ url: URL) -> URL? {
    FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
}
