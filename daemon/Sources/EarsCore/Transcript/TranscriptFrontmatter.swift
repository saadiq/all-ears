/// The YAML frontmatter block of a rendered transcript document, matching the
/// fixed schema shown in `docs/data-formats.md`'s "Transcript format" section
/// field-for-field and in field order:
///
/// ```yaml
/// schema: 1
/// kind: transcript
/// range_run: 2026-07-17T10-30-00Z_standup
/// sources: [mic, "app:us.zoom.xos"]
/// title: Weekly standup
/// started: 2026-07-17T10:30:00Z
/// range: { start: 2026-07-17T10:30:00Z, end: 2026-07-17T11:02:00Z }
/// model: { name: parakeet, backend: fluidaudio, version: "0.x" }
/// diarization: { enabled: true, backend: pyannote }
/// generated: 2026-07-17T11:02:14Z
/// duration_seconds: 1920
/// speech_seconds: 1440
/// word_count: 3120
/// vocab: [global, standup]
/// ```
///
/// `derivedFrom` is only present for `kind: clean` / `kind: summary` documents
/// (see `docs/data-formats.md`); when non-`nil` it renders as a `derived_from`
/// line immediately after `kind`.
public struct TranscriptFrontmatter: Sendable, Hashable {
  public var schema: Int
  public var kind: TranscriptKind
  /// A synthesized run identifier for a plain range run
  /// (`--last`/`--from`/`--to`), in the `<start-timestamp>_<slug>` shape —
  /// see `OutputPathResolution.rangeRunIdentifier`. `nil` for session
  /// transcripts, which carry ``session`` instead; rendered as a `range_run:`
  /// line only when present.
  public var rangeRun: String?
  /// The session UUID this transcript unions the intervals of
  /// (`transcribe --session`); `nil` for plain range transcripts.
  /// Rendered as a `session:` line.
  public var session: String?
  /// The session's display title at the time this document was written —
  /// the `{title}` a downstream stage's path template expands. `nil` for a
  /// transcript with no session context (a plain range run, a `--file` run),
  /// where `{title}` degrades to the slug or the input's basename.
  public var title: String?
  /// When the session (or range) this transcript covers *began*, as distinct
  /// from ``range``'s start: a `--from`/`--to` rerun narrows the range but
  /// not the session, so this is what the date tokens key on. Filing by it
  /// means a call that ran past midnight, or is re-cleaned a week later,
  /// always lands under the day it started. `nil` when there is no session
  /// context; consumers then fall back to `range.start`.
  public var started: Instant?
  /// A link back to the note written *from* this transcript — the inverse of
  /// the `transcript:` link a summary carries, so the pair is navigable from
  /// either end. An Obsidian wikilink when the destination sits inside a
  /// vault (`"[[daily-notes/2026/08/33/…md]]"`), an absolute path otherwise.
  ///
  /// Written by `summarize` after a preset's summary lands, since that is the
  /// only stage that knows both paths: `cleanup` publishes the transcript
  /// before any preset's destination has been resolved, and a preset's `out`
  /// depends on config and on `--out`. A multi-preset run leaves the last
  /// preset's destination here.
  ///
  /// Parsed and re-rendered so a later `cleanup` pass over an already-linked
  /// transcript carries the link forward instead of silently dropping it.
  /// Rendered as a `note:` line, after `title`, only when present.
  public var note: String?
  /// Everyone the session's roster named, local participant included, in
  /// roster order — independent of whether any audio was ever matched to
  /// them.
  ///
  /// The roster is *observed* (the platform names its own participants);
  /// matching a name to an audio track is *derived*, and derivations fail.
  /// Carrying the roster separately is what stops a failed match from erasing
  /// a name the session knew all along: a downstream stage gets the attendee
  /// list even for a call whose speaker attribution collapsed entirely, so the
  /// note it writes still says who was there. Empty for a transcript with no
  /// session context; rendered as an `attendees:` line only when non-empty.
  public var attendees: [String]
  /// What was degraded or inferred about this transcript — speaker
  /// attribution that could not be resolved, a name assigned by elimination
  /// rather than observation.
  ///
  /// Rendered into the document because a warning on stderr is a warning
  /// nobody reads: every failure behind a mislabelled transcript was already
  /// being detected and logged, and the log is not where anyone looks. Empty
  /// for a clean run; rendered as a `warnings:` line only when non-empty.
  public var warnings: [String]
  public var sources: [SourceID]
  public var range: TimeRange
  public var model: TranscriptModelInfo
  public var diarization: TranscriptDiarizationInfo
  /// When this document was rendered. Always a parameter — never the wall clock.
  public var generated: Instant
  public var durationSeconds: Double
  public var speechSeconds: Double
  public var wordCount: Int
  /// Vocabulary list names merged for this run, e.g. `["global", "standup"]`.
  public var vocab: [String]
  /// Names the source transcript this document was derived from
  /// (`cleanup`/`summarize` only); `nil` for `kind: transcript`.
  public var derivedFrom: String?
  /// The `[[summarize.preset]]` name this summary was generated from (e.g.
  /// `brief`); `nil` for `kind: transcript`/`kind: clean`, which have no
  /// preset. Rendered between `kind` and `derived_from` when present, per
  /// `docs/specs/llm-stages.md`'s "frontmatter kind: summary,
  /// preset, and derived_from".
  public var preset: String?
  /// Per-source record of which audio store each source was read from on a
  /// `transcribe --session` run (`session` = per-session copy, `ring` = global
  /// rolling buffer), so a wrong-store read is visible after the fact
  /// (all-ears issue #20). Empty for non-session transcripts; rendered as an
  /// `audio_stores:` line only when non-empty.
  public var audioStores: [TranscriptAudioStore]

  public init(
    schema: Int,
    kind: TranscriptKind,
    rangeRun: String? = nil,
    session: String? = nil,
    title: String? = nil,
    started: Instant? = nil,
    note: String? = nil,
    attendees: [String] = [],
    warnings: [String] = [],
    sources: [SourceID],
    range: TimeRange,
    model: TranscriptModelInfo,
    diarization: TranscriptDiarizationInfo,
    generated: Instant,
    durationSeconds: Double,
    speechSeconds: Double,
    wordCount: Int,
    vocab: [String],
    derivedFrom: String? = nil,
    preset: String? = nil,
    audioStores: [TranscriptAudioStore] = []
  ) {
    self.schema = schema
    self.kind = kind
    self.rangeRun = rangeRun
    self.session = session
    self.title = title
    self.started = started
    self.note = note
    self.attendees = attendees
    self.warnings = warnings
    self.sources = sources
    self.range = range
    self.model = model
    self.diarization = diarization
    self.generated = generated
    self.durationSeconds = durationSeconds
    self.speechSeconds = speechSeconds
    self.wordCount = wordCount
    self.vocab = vocab
    self.derivedFrom = derivedFrom
    self.preset = preset
    self.audioStores = audioStores
  }
}

/// One `audio_stores` entry: which store a single source's audio was read from
/// on a `transcribe --session` run. See ``TranscriptFrontmatter/audioStores``.
public struct TranscriptAudioStore: Sendable, Hashable {
  public var source: SourceID
  /// `"session"` (per-session copy) or `"ring"` (global rolling buffer).
  public var store: String

  public init(source: SourceID, store: String) {
    self.source = source
    self.store = store
  }
}
