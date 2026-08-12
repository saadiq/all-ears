/// Groups a transcript's turns into the batches `cleanup` sends to the LLM as
/// a single call.
///
/// **Why batch at all.** One call per turn is both slow and context-free: a
/// 42-minute meeting produces ~2,500 VAD-bounded turns, and at a few seconds
/// per call the stage runs for hours while the daemon's on-end chain (and so
/// `summarize`) waits behind it. Worse, each turn is corrected in isolation —
/// the model cannot use the surrounding conversation to resolve exactly the
/// errors cleanup exists to fix (a homophone, a name, a term the speakers
/// established two turns earlier). Batching a few minutes of talking into one
/// call fixes both: far fewer round trips, and each turn is corrected with its
/// neighbours in view.
///
/// **Why spoken duration, not turn count or characters.** "Five minutes of
/// talking" is the unit that keeps a chunk's *context* comparable across
/// transcripts. Turn count varies wildly with VAD aggressiveness (a chatty
/// call splits the same minute into three times the turns), and character
/// count tracks speaking rate rather than conversational span. ``maxCharacters``
/// is kept as a second bound, but as a safety valve against a pathological
/// transcript overrunning the model's context — not as the primary knob.
///
/// Pure and total: no clock, no I/O, and every input produces a partition that
/// covers the input exactly once, in order (see ``chunks(of:)``).
public struct CleanupChunker: Sendable {
  /// Target spoken seconds per chunk — the sum of each turn's `end - start`.
  /// Wall-clock gaps between turns are deliberately not counted: a call with
  /// long silences should still batch the same amount of *speech*.
  public var maxSpokenSeconds: Double
  /// Safety bound on a chunk's rendered size. Generous enough that it never
  /// binds on ordinary speech at ``maxSpokenSeconds``, tight enough that a
  /// pathological transcript can't build a prompt no model will accept.
  public var maxCharacters: Int

  public init(maxSpokenSeconds: Double = 300, maxCharacters: Int = 24_000) {
    self.maxSpokenSeconds = max(0, maxSpokenSeconds)
    self.maxCharacters = max(1, maxCharacters)
  }

  /// Partitions `turns` into contiguous ranges, each holding at most
  /// ``maxSpokenSeconds`` of speech and ``maxCharacters`` of text.
  ///
  /// A turn is never split: one that exceeds a bound on its own becomes a
  /// single-turn chunk rather than being cut mid-utterance (the same scope
  /// bound `CleanupPipeline` has always had — segments are naturally short, so
  /// chunking *within* a turn is not a case this stage needs to handle).
  ///
  /// The returned ranges are non-empty, contiguous, in order, and together
  /// cover `0..<turns.count` exactly.
  public func chunks(of turns: [TranscriptSegment]) -> [Range<Int>] {
    guard !turns.isEmpty else { return [] }

    var ranges: [Range<Int>] = []
    var start = 0
    var seconds = 0.0
    var characters = 0

    for (index, turn) in turns.enumerated() {
      let duration = max(0, turn.segment.end - turn.segment.start)
      let length = turn.segment.text.count

      // Close the open chunk *before* adding this turn when it would push
      // either bound past its limit. `index > start` keeps a lone oversized
      // turn from closing an empty chunk and looping forever.
      if index > start
        && (seconds + duration > maxSpokenSeconds || characters + length > maxCharacters)
      {
        ranges.append(start..<index)
        start = index
        seconds = 0
        characters = 0
      }

      seconds += duration
      characters += length
    }

    ranges.append(start..<turns.count)
    return ranges
  }
}
