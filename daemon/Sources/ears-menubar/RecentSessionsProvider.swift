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
  /// How far this session's pipeline got, in `ears sessions`' own vocabulary.
  var outcome: PipelineOutcome
  var id: String { session.id }

  /// Hashed on the session id alone: it already identifies a row, and
  /// ``PipelineOutcome`` is `Equatable` but not `Hashable`, so the synthesized
  /// conformance is unavailable. Equality still compares every field.
  func hash(into hasher: inout Hasher) {
    hasher.combine(session.id)
  }
}

/// Read-only bridge from the on-disk stores to menu items. Never writes —
/// earsd stays the only writer.
struct RecentSessionsProvider: Sendable {
  var dataRoot: String
  var publishing: PublishingSettings
  /// The chain an inheriting session runs, resolved once for the whole scan —
  /// it is a property of the config, not of any one session.
  var onEndChain: [OnEndStage]
  /// The daemon's empty-transcript thresholds, likewise config-wide.
  var emptiness: TranscriptEmptinessPolicy

  func load(limit: Int = 7, now: Instant) -> [RecentSessionItem] {
    let all = SessionStore.readAll(dataRoot: URL(fileURLWithPath: dataRoot))
    return RecentSessions.select(from: all, limit: limit).map { item(for: $0, now: now) }
  }

  /// The published tier is resolved from the raw transcript's own frontmatter
  /// — the context `cleanup` expanded — so no transcript on disk, or one that
  /// will not parse, leaves the published verbs disabled rather than pointing
  /// at a guessed path. That is the honest answer: `cleanup` consumes the
  /// transcript, and retention never sweeps it (it deletes `sources/` only), so
  /// a missing transcript means the chain never got that far.
  private func item(for session: Session, now: Instant) -> RecentSessionItem {
    let transcriptURL = SessionArtifactLocator.rawTranscript(
      dataRoot: dataRoot, sessionID: session.id)
    let transcript = existing(transcriptURL)

    // Only the fields `outcome` reads: the capture and attribution figures are
    // `ears session show`'s detail, and sizing every session's `sources/`
    // directory on every menu open would cost a full store walk for a line
    // this menu never renders. Existence is a fact of the file, not of the
    // parse — a transcript that will not parse still exists, and saying
    // otherwise would render "no transcript" beside an enabled Open
    // Transcript verb.
    var artifacts = SessionArtifacts()
    artifacts.transcriptExists = transcript != nil

    guard let frontmatter = parseFrontmatter(transcriptURL) else {
      return RecentSessionItem(
        session: session, transcript: transcript, clean: nil, summaries: [],
        outcome: outcome(session: session, artifacts: artifacts, now: now))
    }
    // The two measurements the daemon's gate reads. Without them `outcome`
    // cannot tell a chain the daemon deliberately stopped from one still
    // waiting on a note, and renders the former as the latter forever.
    artifacts.transcriptWords = frontmatter.wordCount
    artifacts.transcriptSpeechSeconds = frontmatter.speechSeconds

    let paths = SessionArtifactLocator.published(
      frontmatter: frontmatter, transcriptPath: transcriptURL.path,
      settings: publishing)
    let clean = existing(paths.clean)
    let summaries = summaries(paths)
    artifacts.cleanupExists = clean != nil
    artifacts.noteLink = clean.flatMap { parseFrontmatter($0)?.note }

    return RecentSessionItem(
      session: session,
      transcript: transcript,
      clean: clean,
      summaries: summaries,
      outcome: outcome(session: session, artifacts: artifacts, now: now))
  }

  private func outcome(
    session: Session, artifacts: SessionArtifacts, now: Instant
  ) -> PipelineOutcome {
    SessionPipeline.outcome(
      session: session, artifacts: artifacts, now: now, configuredChain: onEndChain,
      emptiness: emptiness)
  }

  /// Frontmatter only: the published-path context and `outcome` never read
  /// the body or the JSON sidecar, and the full parse would refuse a document
  /// whose body a vault tool reflowed even though the frontmatter this needs
  /// is intact.
  private func parseFrontmatter(_ markdownURL: URL) -> TranscriptFrontmatter? {
    guard let markdown = try? String(contentsOf: markdownURL, encoding: .utf8) else { return nil }
    return try? TranscriptParser.parseFrontmatter(markdown)
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
