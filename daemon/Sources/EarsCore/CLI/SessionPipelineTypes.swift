/// What a disk scan of one session's directory (and its downstream published
/// artifacts) found. Assembled by the `ears` executable's scanner; consumed
/// by ``SessionPipeline``'s pure derivation.
public struct SessionArtifacts: Sendable, Equatable {
  /// On-disk bytes per session-scoped source copy (`sessions/<id>/sources/`).
  public var captureBytesBySource: [SourceID: Int] = [:]
  /// Whether `attribution.jsonl` exists — the gate on any speech/silence
  /// claim (no log, no claim).
  public var hasAttributionLog = false
  /// Capture handles (`t1`) with at least one decoded speech onset — see
  /// ``AttributionSpeechEvidence/speechCaptures``.
  public var speechCaptures: Set<String> = []
  /// Whether `sessions/<id>/transcript.md` exists.
  public var transcriptExists = false
  /// Its absolute path, when it exists — carried for the `--json` view.
  public var transcriptPath: String?
  /// Turn count parsed from the transcript, when it parsed.
  public var transcriptSegments: Int?
  /// `word_count` from the transcript's frontmatter, when it parsed.
  public var transcriptWords: Int?
  /// Where `[cleanup] output` resolves for this session's transcript —
  /// computed whether or not anything is there yet.
  public var cleanupPath: String?
  /// Whether ``cleanupPath`` exists on disk.
  public var cleanupExists = false
  /// Turn count parsed from the cleaned transcript, when it parsed.
  public var cleanupSegments: Int?
  /// `*.summary.md` siblings derived from the cleaned transcript.
  public var summaryCount = 0
  /// The `note:` frontmatter link stamped into the cleaned transcript by
  /// `summarize` — the published note, in wikilink or absolute-path form.
  public var noteLink: String?

  public init() {}
}

/// One row of the `ears session show` pipeline view.
public struct PipelineStage: Sendable, Equatable {
  public var name: String
  public var state: PipelineStageState
  public var detail: String

  public init(name: String, state: PipelineStageState, detail: String) {
    self.name = name
    self.state = state
    self.detail = detail
  }
}

/// A stage's derived condition. `missing` is deliberately neutral wording:
/// from disk alone, "artifact absent long after the session ended" is
/// distinguishable from "still in flight" but not from a stage that failed, so
/// the view never claims failure outright. A stage the session's on-end chain
/// never asked for is `notRequested` — an absence with a reason, not a gap.
public enum PipelineStageState: String, Sendable, Equatable, Codable {
  case done
  case running
  case waiting
  case missing
  case notRequested = "not-requested"
}

/// A one-line pipeline outcome: a status glyph and its text.
public struct PipelineOutcome: Sendable, Equatable {
  public var glyph: String
  public var text: String

  public init(glyph: String, text: String) {
    self.glyph = glyph
    self.text = text
  }
}
