/// Renders the Markdown body — the sequence of speaker turns and their text
/// below the frontmatter — from an ordered list of ``TranscriptSegment``.
///
/// Each `TranscriptSegment` is already one turn (see its doc comment); this
/// renderer's only job is formatting, in two shapes:
///
/// - **A turn** is a bold label line, `**[HH:MM:SS] <speaker>**` (optionally
///   followed by a `<!-- source: ... -->` provenance comment), then the text on
///   the next line, with turns separated by a blank line.
/// - **A backchannel** (``TranscriptSegment/isBackchannel``) is a blockquote
///   line, `> [HH:MM:SS] <speaker>: <text>`, appended to the turn it
///   interrupted rather than starting a turn of its own.
///
/// The label used to be an `##` heading. It stopped being one because a
/// speaker name is metadata, not document structure: a one-word "Yeah."
/// rendered at display size, inverting the visual weight so the least content
/// got the most emphasis, and the per-turn outline it bought was a thousand
/// entries named after two people. ``TranscriptParser`` still reads the old
/// heading form, so transcripts written before this change keep round-tripping.
enum MarkdownBodyRenderer {
  static func render(_ segments: [TranscriptSegment], rangeStart: Instant) -> String {
    var blocks: [String] = []
    for turn in segments {
      let line = renderTurn(turn, rangeStart: rangeStart)
      // A backchannel folds into the preceding block. With no preceding block
      // it has nothing to attach to and stands alone as an ordinary turn.
      if turn.isBackchannel, let last = blocks.indices.last {
        blocks[last] += "\n" + line
      } else {
        blocks.append(line)
      }
    }
    return blocks.joined(separator: "\n\n")
  }

  private static func renderTurn(_ turn: TranscriptSegment, rangeStart: Instant) -> String {
    let time = UTCCalendar.timeOfDay(rangeStart.advanced(by: turn.segment.start))

    if turn.isBackchannel {
      return "> [\(time)] \(turn.speaker): \(turn.segment.text)"
    }

    var label = "**[\(time)] \(turn.speaker)**"
    if turn.sourceProvenance {
      label += "  <!-- source: \(turn.source.rawValue) -->"
    }
    return label + "\n" + turn.segment.text
  }
}
