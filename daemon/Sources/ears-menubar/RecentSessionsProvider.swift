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
    return RecentSessions.select(from: all, limit: limit).map { session in
      let paths = SessionArtifactLocator.published(for: session, settings: publishing)
      return RecentSessionItem(
        session: session,
        transcript: existing(
          SessionArtifactLocator.rawTranscript(dataRoot: dataRoot, sessionID: session.id)),
        clean: existing(paths.clean),
        summaries: summaries(paths))
    }
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
