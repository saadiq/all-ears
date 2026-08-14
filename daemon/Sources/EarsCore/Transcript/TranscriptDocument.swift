/// A full transcript document: frontmatter plus the ordered turns that make up
/// the Markdown body and the JSON sidecar. Both renderings come from this one
/// value, which is how `docs/data-formats.md` guarantees they never disagree.
public struct TranscriptDocument: Sendable, Hashable {
  public var frontmatter: TranscriptFrontmatter
  public var segments: [TranscriptSegment]
  /// The speaker map this run's turns were labelled with — the session's
  /// stored `[[speaker]]` map, or the fresh re-derivation a
  /// `transcribe --session` run computed (which is never written back to
  /// `session.toml`). Rendered into the JSON sidecar only: the Markdown
  /// already shows the map through its turn labels, but a segment-less run
  /// (audio evicted, or a null test backend) would otherwise leave the
  /// conclusion with no durable record — and an offline replay of an archived
  /// session through the current reconciler reads it from exactly there.
  /// Empty for a document with no session context.
  public var speakers: [SessionSpeaker]

  public init(
    frontmatter: TranscriptFrontmatter, segments: [TranscriptSegment],
    speakers: [SessionSpeaker] = []
  ) {
    self.frontmatter = frontmatter
    self.segments = segments
    self.speakers = speakers
  }
}
