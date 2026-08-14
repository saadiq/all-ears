import EarsCore
import EarsDataStore
import Foundation

/// Resolves where a `transcribe` run's Markdown transcript and JSON sidecar
/// land inside the **data store**.
///
/// A raw transcript is an intermediate, not a deliverable: it is addressed by
/// session (or by range-run identifier) and has no user-facing layout at all.
/// Only `cleanup` publishes, and it publishes through `[cleanup] output`'s
/// path template into `output_root`. So nothing here consults `output_root`.
///
/// Pure `URL` construction only — no filesystem access — over
/// ``DataStoreLayout``'s own path vocabulary, so path shape is unit-tested
/// without touching disk.
enum TranscriptStorePaths {
  struct Paths: Equatable {
    var markdown: URL
    var sidecar: URL
  }

  /// `--out`, used verbatim as the Markdown path; the JSON sidecar swaps its
  /// extension to `.json`.
  static func explicit(_ out: String) -> Paths {
    paths(markdown: URL(fileURLWithPath: out))
  }

  /// A `--session` run: `<data-root>/sessions/<id>/transcript.{md,json}`.
  static func session(dataRoot: URL, sessionID: String) -> Paths {
    paths(
      markdown: DataStoreLayout.sessionTranscriptFile(dataRoot: dataRoot, sessionID: sessionID))
  }

  /// A `--last`/`--from`/`--to` run, which has no session directory:
  /// `<data-root>/runs/<range-run-id>.transcript.{md,json}`.
  static func rangeRun(dataRoot: URL, runIdentifier: String) -> Paths {
    paths(
      markdown: DataStoreLayout.rangeRunTranscriptFile(
        dataRoot: dataRoot, runIdentifier: runIdentifier))
  }

  /// A `--follow` run's live transcript, kept apart from the session's
  /// authoritative batch transcript (see
  /// ``DataStoreLayout/sessionFollowTranscriptFile(dataRoot:sessionID:sourceID:)``).
  static func follow(dataRoot: URL, sessionID: String, sourceID: SourceID) -> Paths {
    paths(
      markdown: DataStoreLayout.sessionFollowTranscriptFile(
        dataRoot: dataRoot, sessionID: sessionID, sourceID: sourceID))
  }

  /// Synthesises a run identifier for a plain `--last`/`--from`/`--to` run, in
  /// the `<start-timestamp>_<slug>` shape (e.g. `2026-07-17T10-30-00Z_mic`) —
  /// both the transcript's `range_run:` frontmatter value and its filename
  /// stem under `runs/`. A `--session` run uses the session id instead.
  static func rangeRunIdentifier(requestedStart: Instant, sourceIDs: [SourceID]) -> String {
    let timestamp = FilenameTimestampCodec.string(for: requestedStart)
    let slug = sourceIDs.map(\.pathSafe).joined(separator: "_")
    return "\(timestamp)_\(slug)"
  }

  /// The sidecar is always the Markdown path with `.md` swapped for `.json` —
  /// the one naming rule every stage (`cleanup`, `summarize`) also follows,
  /// so a sidecar is findable from a Markdown path alone.
  private static func paths(markdown: URL) -> Paths {
    Paths(
      markdown: markdown,
      sidecar: markdown.deletingPathExtension().appendingPathExtension("json"))
  }
}
