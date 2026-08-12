import EarsCore
import Foundation

/// On-disk path layout under a data root, per `docs/data-formats.md`'s
/// "Directory layout" section. Pure `URL` construction only -- no filesystem
/// access happens here, so this is unit-tested without touching disk even
/// though every other type in this module is I/O-heavy.
public enum DataStoreLayout {
  /// `<data-root>/sources/` — the parent of every source directory, enumerated
  /// by the daemon's eviction sweep to find sources with no live actor.
  public static func sourcesRootDirectory(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("sources")
  }

  /// `<data-root>/sources/<source-id-path-safe>/`.
  public static func sourceDirectory(dataRoot: URL, sourceID: SourceID) -> URL {
    sourcesRootDirectory(dataRoot: dataRoot).appendingPathComponent(sourceID.pathSafe)
  }

  /// `<data-root>/sources/<source-id-path-safe>/chunks/`, the native-rate
  /// listenable copy.
  public static func chunksDirectory(dataRoot: URL, sourceID: SourceID) -> URL {
    sourceDirectory(dataRoot: dataRoot, sourceID: sourceID).appendingPathComponent("chunks")
  }

  /// `<data-root>/sources/<source-id-path-safe>/asr/`, the derived
  /// 16 kHz ASR feed.
  public static func asrDirectory(dataRoot: URL, sourceID: SourceID) -> URL {
    sourceDirectory(dataRoot: dataRoot, sourceID: sourceID).appendingPathComponent("asr")
  }

  /// `<data-root>/sources/<source-id-path-safe>/chunks.jsonl` — the small
  /// **structural** index (chunk/gap/evict events), read whole at startup to
  /// reconstruct the live chunk set. VAD events live apart, under ``vadDirectory``
  /// (see `docs/data-formats.md`'s "The index"), so this log stays tiny.
  public static func structuralIndexFile(dataRoot: URL, sourceID: SourceID) -> URL {
    sourceDirectory(dataRoot: dataRoot, sourceID: sourceID).appendingPathComponent("chunks.jsonl")
  }

  /// `<data-root>/sources/<source-id-path-safe>/vad/` — the directory of
  /// size/time-rotated VAD segments (`<timestamp>.jsonl`). Whole segments are
  /// unlinked once they age past the source's time cap.
  public static func vadDirectory(dataRoot: URL, sourceID: SourceID) -> URL {
    sourceDirectory(dataRoot: dataRoot, sourceID: sourceID).appendingPathComponent("vad")
  }

  /// `<data-root>/sources/<source-id-path-safe>/vad/<timestamp>.jsonl` — one VAD
  /// segment, named by its first event's start (``FilenameTimestampCodec``) so
  /// segments sort chronologically by filename and eviction is a filename-only
  /// decision.
  public static func vadSegmentFile(dataRoot: URL, sourceID: SourceID, start: Instant) -> URL {
    vadDirectory(dataRoot: dataRoot, sourceID: sourceID)
      .appendingPathComponent("\(FilenameTimestampCodec.string(for: start)).jsonl")
  }

  /// `<data-root>/sources/<source-id-path-safe>/meta.toml`.
  public static func metaTomlFile(dataRoot: URL, sourceID: SourceID) -> URL {
    sourceDirectory(dataRoot: dataRoot, sourceID: sourceID).appendingPathComponent("meta.toml")
  }

  /// `<data-root>/sessions/`.
  public static func sessionsDirectory(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("sessions")
  }

  /// `<data-root>/sessions/<session-id>/`.
  public static func sessionDirectory(dataRoot: URL, sessionID: String) -> URL {
    sessionsDirectory(dataRoot: dataRoot).appendingPathComponent(sessionID)
  }

  /// `<data-root>/sessions/<session-id>/session.toml`.
  public static func sessionTomlFile(dataRoot: URL, sessionID: String) -> URL {
    sessionDirectory(dataRoot: dataRoot, sessionID: sessionID).appendingPathComponent(
      "session.toml")
  }

  /// `<data-root>/sessions/<session-id>/transcript.md` — the session's raw
  /// transcript, an **intermediate**: addressed by session, with no
  /// user-facing layout. The published, cleaned transcript is `cleanup`'s
  /// concern and lands wherever `[cleanup] output` resolves to.
  ///
  /// Kept here rather than swept with the audio: once the audio is evicted
  /// this file is the only route to re-running cleanup/summarize with a
  /// different prompt or model (`docs/specs/capture-daemon.md`'s retention
  /// section).
  public static func sessionTranscriptFile(dataRoot: URL, sessionID: String) -> URL {
    sessionDirectory(dataRoot: dataRoot, sessionID: sessionID)
      .appendingPathComponent("transcript.md")
  }

  /// `<data-root>/sessions/<session-id>/<source>.follow.transcript.md` — the
  /// live transcript a `transcribe --follow` run rewrites on every commit.
  /// Named apart from ``sessionTranscriptFile(dataRoot:sessionID:)`` so a
  /// follow run and the session's authoritative batch transcript never
  /// overwrite one another, and per-source so two followers of one session
  /// don't collide.
  public static func sessionFollowTranscriptFile(
    dataRoot: URL, sessionID: String, sourceID: SourceID
  ) -> URL {
    sessionDirectory(dataRoot: dataRoot, sessionID: sessionID)
      .appendingPathComponent("\(sourceID.pathSafe).follow.transcript.md")
  }

  /// `<data-root>/runs/` — where a range run (`--last`/`--from`/`--to`), which
  /// has no session directory to live in, files its intermediate transcript.
  public static func runsDirectory(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("runs")
  }

  /// `<data-root>/runs/<range-run-id>.transcript.md`, keyed by the same
  /// `<start-timestamp>_<slug>` identifier the transcript's `range_run:`
  /// frontmatter carries.
  public static func rangeRunTranscriptFile(dataRoot: URL, runIdentifier: String) -> URL {
    runsDirectory(dataRoot: dataRoot).appendingPathComponent("\(runIdentifier).transcript.md")
  }

  /// The `chunks/<filename>` or `asr/<filename>` path recorded in
  /// `index.jsonl`'s `chunk`/`evict` events -- relative to the source
  /// directory, matching the doc's literal examples
  /// (`"file":"chunks/2026-07-17T10-30-00Z.m4a"`).
  public static func relativeChunkPath(subdirectory: ChunkSubdirectory, filename: String) -> String
  {
    "\(subdirectory.rawValue)/\(filename)"
  }
}

/// The two per-chunk feeds a source stores, per `docs/data-formats.md`'s
/// "Dual-rate audio storage" section.
public enum ChunkSubdirectory: String, Sendable, Hashable {
  case chunks
  case asr
}
