import Testing

@testable import EarsCore

/// Round-trips the Markdown body through ``MarkdownBodyRenderer`` and
/// ``TranscriptParser``. `cleanup` and `summarize` both read a transcript back
/// off disk, so the two must agree exactly — a renderer change that the parser
/// does not follow silently breaks every downstream stage.
@Suite("Transcript Markdown round-trip")
struct TranscriptMarkdownRoundTripTests {
  private let rangeStart = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z
  private let fallback = SourceID("mic")

  private func frontmatter() -> String { "---\nschema: 1\n---\n" }

  private func roundTrip(_ segments: [TranscriptSegment]) throws -> [TranscriptSegment] {
    let body = MarkdownBodyRenderer.render(segments, rangeStart: rangeStart)
    return try TranscriptParser.parseMarkdownSegments(
      frontmatter() + "\n" + body, rangeStart: rangeStart, fallbackSource: fallback)
  }

  @Test("a plain turn survives the round trip")
  func plainTurn() throws {
    let turns = [
      TranscriptSegment(
        source: "mic", speaker: "You", segment: Segment(start: 4, end: 6, text: "Any blockers?"))
    ]
    let parsed = try roundTrip(turns)
    #expect(parsed.map(\.speaker) == ["You"])
    #expect(parsed.map(\.segment.text) == ["Any blockers?"])
    #expect(parsed.map(\.isBackchannel) == [false])
    #expect(parsed.map(\.segment.start) == [4])
  }

  @Test("a backchannel keeps its speaker, text, timing, and flag")
  func backchannelRoundTrip() throws {
    let turns = [
      TranscriptSegment(
        source: "app:zoom", speaker: "Alan",
        segment: Segment(start: 10, end: 40, text: "So the plan is basically this.")),
      TranscriptSegment(
        source: "mic", speaker: "You", segment: Segment(start: 20, end: 21, text: "Right."),
        isBackchannel: true),
    ]
    let parsed = try roundTrip(turns)
    #expect(parsed.map(\.speaker) == ["Alan", "You"])
    #expect(parsed.map(\.segment.text) == ["So the plan is basically this.", "Right."])
    #expect(parsed.map(\.isBackchannel) == [false, true])
    // The backchannel's own timestamp survives, not the host's.
    #expect(parsed.map(\.segment.start) == [10, 20])
  }

  @Test("several backchannels under one turn all come back, in order")
  func manyBackchannels() throws {
    let turns = [
      TranscriptSegment(
        source: "app:zoom", speaker: "Alan",
        segment: Segment(start: 0, end: 60, text: "A long stretch of talking.")),
      TranscriptSegment(
        source: "mic", speaker: "You", segment: Segment(start: 10, end: 11, text: "Right."),
        isBackchannel: true),
      TranscriptSegment(
        source: "mic", speaker: "You", segment: Segment(start: 20, end: 21, text: "Okay."),
        isBackchannel: true),
      TranscriptSegment(
        source: "mic", speaker: "You", segment: Segment(start: 30, end: 31, text: "Yeah. Yep."),
        isBackchannel: true),
    ]
    let parsed = try roundTrip(turns)
    #expect(
      parsed.map(\.segment.text) == ["A long stretch of talking.", "Right.", "Okay.", "Yeah. Yep."])
    #expect(parsed.map(\.isBackchannel) == [false, true, true, true])
  }

  @Test("the source-provenance comment survives alongside the bold label")
  func provenanceRoundTrip() throws {
    let turns = [
      TranscriptSegment(
        source: "app:us.zoom.xos", speaker: "Speaker 2",
        segment: Segment(start: 11, end: 14, text: "Nothing from me."),
        sourceProvenance: true)
    ]
    let parsed = try roundTrip(turns)
    #expect(parsed.map(\.speaker) == ["Speaker 2"])
    #expect(parsed.map(\.source) == [SourceID("app:us.zoom.xos")])
    #expect(parsed.map(\.sourceProvenance) == [true])
  }

  @Test("transcripts written before the bold label still parse")
  func legacyHeadingForm() throws {
    // Every transcript on disk predating this change uses `## [ts] speaker`.
    // Dropping support would break cleanup and summarize on all of them.
    let markdown = """
      ---
      schema: 1
      ---

      ## [10:30:04] You
      Morning — let's keep this quick.

      ## [10:30:11] Speaker 2  <!-- source: app:us.zoom.xos -->
      Nothing from me.
      """
    let parsed = try TranscriptParser.parseMarkdownSegments(
      markdown, rangeStart: rangeStart, fallbackSource: fallback)
    #expect(parsed.map(\.speaker) == ["You", "Speaker 2"])
    #expect(parsed.map(\.segment.text) == ["Morning — let's keep this quick.", "Nothing from me."])
    #expect(parsed.map(\.source) == [SourceID("mic"), SourceID("app:us.zoom.xos")])
    #expect(parsed.map(\.isBackchannel) == [false, false])
  }

  @Test("a multi-line turn body keeps its newlines")
  func multiLineBody() throws {
    let markdown = """
      ---
      schema: 1
      ---

      **[10:30:04] You**
      First line.
      Second line.
      """
    let parsed = try TranscriptParser.parseMarkdownSegments(
      markdown, rangeStart: rangeStart, fallbackSource: fallback)
    #expect(parsed.map(\.segment.text) == ["First line.\nSecond line."])
  }
}
