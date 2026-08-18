import Foundation

/// Where `cleanup` publishes, as a pure function of the input transcript —
/// the template context assembled from the document's own frontmatter, and
/// the fallback stem derived from the input path.
///
/// Shared between the `cleanup` stage itself (the writer) and `ears session
/// show` (which reconstructs a session's pipeline state from disk and must
/// resolve the *same* published path without re-running the stage). One
/// definition means the two can never disagree about where an artifact
/// landed.
public enum CleanupPublishedPath {
  /// The path-template context for a cleanup run over `frontmatter`'s
  /// document:
  ///
  /// - `{title}` is the session title the transcript recorded; absent (a
  ///   plain range run, a `--file` run) it degrades to `{slug}`.
  /// - `{slug}` is the document's path-safe source list — which, for a
  ///   `--file` transcript, *is* the input file's basename, since
  ///   `transcribe --file` names its source after the file.
  /// - dates come from `started:` when the transcript carries it, so a
  ///   narrowed rerun still files under the day the session began.
  public static func context(
    outputRoot: String,
    weekNumbering: WeekNumbering,
    frontmatter: TranscriptFrontmatter,
    transcriptPath: String
  ) -> PathTemplate.Context {
    PathTemplate.Context(
      outputRoot: outputRoot,
      start: frontmatter.started ?? frontmatter.range.start,
      weekNumbering: weekNumbering,
      session: frontmatter.session,
      slug: frontmatter.sources.map(\.pathSafe).joined(separator: "_"),
      title: frontmatter.title,
      fallbackName: documentStem(URL(fileURLWithPath: transcriptPath)))
  }

  /// Where a cleanup run's JSON sidecar lands: beside the **input**
  /// transcript, `.md` swapped for `.clean.json` —
  /// `sessions/<uuid>/transcript.md` → `sessions/<uuid>/transcript.clean.json`.
  ///
  /// The sidecar is machine-facing (word timings, confidence), so it stays in
  /// the data store with the intermediate it was derived from. Only the
  /// cleaned Markdown publishes to the user-facing output — a `.json` beside
  /// a vault note is pollution, not a deliverable.
  public static func cleanSidecarURL(forInput url: URL) -> URL {
    url.deletingPathExtension()
      .appendingPathExtension("clean")
      .appendingPathExtension("json")
  }

  /// The input's basename with any known transcript suffix stripped, the
  /// last-resort stand-in when a document carries neither a title nor
  /// sources: `standup.transcript.md` → `standup`.
  public static func documentStem(_ url: URL) -> String {
    let name = url.lastPathComponent
    for suffix in [".transcript.md", ".clean.md", ".summary.md"] where name.hasSuffix(suffix) {
      return String(name.dropLast(suffix.count))
    }
    return url.deletingPathExtension().lastPathComponent
  }
}
