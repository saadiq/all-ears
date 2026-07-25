import EarsCore

/// One source's ASR output for a `transcribe` run: its raw ``Segment``s,
/// already time-shifted so `start`/`end` are relative to the *overall*
/// requested range rather than to whichever ``AudioSlice`` they came from
/// (each ``Segment`` from a ``Transcriber`` is relative to the audio buffer
/// it decoded, per that type's doc comment -- ``TranscribePipeline`` performs
/// that shift before handing segments here).
struct SourceTranscription {
  var sourceID: SourceID
  var segments: [Segment]
}

/// Builds the final ``TranscriptDocument`` for a `transcribe` run: merges
/// every source's segments onto one shared timeline ordered by time (per
/// `docs/specs/transcribe.md`'s "merge sources on a shared timeline" step),
/// assigns speaker labels, and fills in the frontmatter.
///
/// Pure -- no I/O, no clock read of its own (`generated` is a parameter) --
/// so it's unit-tested directly; ``TranscribePipeline`` is the only caller
/// and owns turning real ``AudioSlice``/``Transcriber`` output into the
/// ``SourceTranscription`` values this takes.
enum TranscriptAssembly {
  /// Speaker label for a source with no diarization stage (not implemented
  /// yet -- see `docs/specs/model-interface.md`'s `Diarizer`
  /// protocol, out of scope for this pass): a `speakers` name-map entry
  /// (`docs/data-formats.md`'s `[speakers]` -- e.g. a meeting roster's
  /// attendee names) wins; otherwise `mic` maps to `You` per the
  /// source-level attribution rule; any other source is labelled with its
  /// own raw source id, a defensible placeholder until per-speaker
  /// diarization exists.
  ///
  /// Because the merge groups turns by this *resolved label* rather than by
  /// the raw source id, two source ids that resolve to the same label are
  /// coalesced into one speaker. That is what unifies a participant across a
  /// Meet identity upgrade: the roster's `[speakers]` map (attendee `source`
  /// -> `display_name`, threaded in by ``TranscribePipeline``) points both
  /// the pre- and post-upgrade sources at the same Meet display name, so they
  /// render under one consistent label instead of two.
  static func speakerLabel(
    for sourceID: SourceID, speakers: [String: String] = [:]
  ) -> String {
    if let name = speakers[sourceID.rawValue] { return name }
    return sourceID == SourceID("mic") ? "You" : sourceID.rawValue
  }

  /// Refines a source's base speaker label with the diarizer's within-source
  /// `Speaker N` split, per `docs/specs/model-interface.md`: **source
  /// attribution stays primary; the diarizer only adds a sub-label.** A segment
  /// is attributed to the ``SpeakerSpan`` covering its midpoint (falling back to
  /// the maximum-overlap span), yielding e.g. `Priya's call · Speaker 2`. With
  /// no spans for the source (mic, per-participant browser streams, or
  /// diarization off), or a segment no span covers, the base label is returned
  /// unchanged — so a non-diarized transcript is byte-identical to before.
  static func refinedLabel(
    base: String, segment: Segment, spans: [SpeakerSpan]
  ) -> String {
    label(base: base, start: segment.start, end: segment.end, spans: spans)
  }

  /// Splits one source segment into per-speaker turns using the diarizer's
  /// within-source `Speaker N` spans. Each word is attributed to the span
  /// covering its midpoint (maximum-overlap fallback); a run of consecutive
  /// words sharing a speaker becomes one turn, its text synthesised from those
  /// words. This is what makes diarization visible when a single ``Transcriber``
  /// segment covers a whole multi-speaker recording — e.g. a standalone `.m4a`
  /// file, decoded as one slice, whose 4-speaker Sortformer output would
  /// otherwise collapse to whichever speaker owns the segment's midpoint.
  ///
  /// Returns a single turn — the **original** segment untouched — when the
  /// segment has no words, no spans cover it, or every word resolves to the
  /// same speaker. So a single-speaker segment keeps its authoritative text
  /// (not text re-joined from words), and a non-diarized transcript stays
  /// byte-identical to before.
  static func diarizedTurns(
    source: SourceID, base: String, segment: Segment, spans: [SpeakerSpan]
  ) -> [TranscriptSegment] {
    func turn(_ speaker: String, _ seg: Segment) -> TranscriptSegment {
      TranscriptSegment(source: source, speaker: speaker, segment: seg, sourceProvenance: false)
    }
    guard !spans.isEmpty, !segment.words.isEmpty else {
      return [turn(refinedLabel(base: base, segment: segment, spans: spans), segment)]
    }

    // Group consecutive words by the speaker label covering each word, so an
    // uninterrupted run by one speaker stays a single turn.
    var groups: [(speaker: String, words: [WordTiming])] = []
    for word in segment.words {
      var speaker = label(base: base, start: word.start, end: word.end, spans: spans)
      // A word landing in a silence gap *between* spans resolves to `base` (no
      // `· Speaker N`). Rather than break the flow into a bare one-word turn,
      // fold it into whoever is currently talking — the gap is a pause within
      // their turn, not a new speaker. A leading gap (before any span) has no
      // prior speaker and stays `base`.
      if speaker == base, let last = groups.last { speaker = last.speaker }
      if let lastIndex = groups.indices.last, groups[lastIndex].speaker == speaker {
        groups[lastIndex].words.append(word)
      } else {
        groups.append((speaker, [word]))
      }
    }

    // One speaker across the whole segment: keep the original segment (and its
    // authoritative text), exactly as the midpoint-based label did.
    guard groups.count > 1 else { return [turn(groups[0].speaker, segment)] }

    // Preserve the segment's own outer bounds on the first/last pieces so the
    // split covers exactly the original span with no gaps at the edges.
    var result: [TranscriptSegment] = []
    for (index, group) in groups.enumerated() {
      let start = index == 0 ? segment.start : group.words[0].start
      let end = index == groups.count - 1 ? segment.end : group.words[group.words.count - 1].end
      result.append(turn(group.speaker, slice(segment, words: group.words, start: start, end: end)))
    }
    return result
  }

  /// The `base · Speaker N` label for the interval `[start, end)`: the span
  /// covering its midpoint wins, else the maximum-overlap span, else `base`
  /// unchanged (no spans, or none overlap). The shared core of both
  /// ``refinedLabel`` (whole-segment) and per-word attribution in
  /// ``diarizedTurns``.
  private static func label(
    base: String, start: Double, end: Double, spans: [SpeakerSpan]
  ) -> String {
    guard !spans.isEmpty else { return base }
    let midpoint = (start + end) / 2
    if let covering = spans.first(where: { $0.start <= midpoint && midpoint < $0.end }) {
      return "\(base) · \(covering.speaker)"
    }
    var best: (span: SpeakerSpan, overlap: Double)?
    for span in spans {
      let overlap = min(end, span.end) - max(start, span.start)
      if overlap > 0, best == nil || overlap > best!.overlap {
        best = (span, overlap)
      }
    }
    if let best { return "\(base) · \(best.span.speaker)" }
    return base
  }

  static func assemble(
    sourceIDs: [SourceID],
    transcriptions: [SourceTranscription],
    requested: TimeRange,
    sessionIdentifier: String,
    meeting: String? = nil,
    speakers: [String: String] = [:],
    diarization: [SourceID: [SpeakerSpan]] = [:],
    diarizationBackend: String? = nil,
    model: TranscriptModelInfo,
    generated: Instant,
    speechSeconds: Double,
    audioStores: [TranscriptAudioStore] = []
  ) -> TranscriptDocument {
    var turns: [TranscriptSegment] = []
    for transcription in transcriptions {
      let base = speakerLabel(for: transcription.sourceID, speakers: speakers)
      let spans = diarization[transcription.sourceID] ?? []
      for segment in transcription.segments {
        turns.append(
          contentsOf: diarizedTurns(
            source: transcription.sourceID, base: base, segment: segment, spans: spans))
      }
    }
    let ordered = interleave(turns)

    // Word count is computed after interleaving, but is invariant to it: a
    // split partitions a segment's words across its two halves (their counts
    // sum back to the original), and an unsplit turn keeps its own words, so
    // the total matches the pre-interleave count exactly.
    let wordCount = ordered.reduce(0) { total, turn in
      let words =
        turn.segment.words.isEmpty
        ? turn.segment.text.split(whereSeparator: \.isWhitespace).count
        : turn.segment.words.count
      return total + words
    }

    let frontmatter = TranscriptFrontmatter(
      schema: 1,
      kind: .transcript,
      session: sessionIdentifier,
      meeting: meeting,
      sources: sourceIDs,
      range: requested,
      model: model,
      diarization: TranscriptDiarizationInfo(
        enabled: !diarization.isEmpty,
        backend: diarization.isEmpty ? nil : diarizationBackend),
      generated: generated,
      durationSeconds: requested.duration,
      speechSeconds: speechSeconds,
      wordCount: wordCount,
      vocab: [],
      audioStores: audioStores
    )

    return TranscriptDocument(frontmatter: frontmatter, segments: ordered)
  }

  /// Weaves every source's turns into one chronological stream, splitting a
  /// turn at word boundaries wherever another speaker begins speaking *during*
  /// it — so a long continuous segment no longer swallows the shorter replies
  /// that overlap it (per `docs/specs/transcribe.md`'s "merge sources on a
  /// shared timeline" step and this PR's acceptance criteria).
  ///
  /// Guarantees:
  /// - **Non-decreasing starts.** Each iteration emits the turn with the
  ///   minimum start currently pending and only re-queues remainders that
  ///   start strictly later, so emitted starts never decrease.
  /// - **No fragmentation without overlap.** A turn is split only where a
  ///   *different-speaker* turn starts inside its span; single-speaker runs
  ///   (and single-source transcripts) are never split, so their turns — and
  ///   the whole document's bytes — are identical to ordering by `start`
  ///   alone.
  /// - **Word granularity, whole-segment fidelity.** Splitting cuts on word
  ///   start times and synthesises the piece's text from its words; an unsplit
  ///   turn keeps its original ``Segment`` (and thus its exact `text`)
  ///   untouched.
  /// - **Wordless fallback.** A segment with no word timings can't be split
  ///   (it has no internal boundaries) and is emitted whole, ordered by
  ///   `start` — but it can still act as the intruder that splits a
  ///   *word-timed* segment, so a mic reply without word timings still lands
  ///   at its own time inside another source's turn.
  private static func interleave(_ turns: [TranscriptSegment]) -> [TranscriptSegment] {
    // Ascending by start, input order preserved on ties (stable) so equal-time
    // turns keep a deterministic, source-then-segment ordering.
    var pending =
      turns
      .enumerated()
      .sorted {
        $0.element.segment.start != $1.element.segment.start
          ? $0.element.segment.start < $1.element.segment.start
          : $0.offset < $1.offset
      }
      .map { $0.element }

    var result: [TranscriptSegment] = []
    while !pending.isEmpty {
      let turn = pending.removeFirst()

      // Earliest point at which a different speaker starts talking strictly
      // inside this turn — the only place worth splitting.
      var cut: Double?
      for other in pending where intrudes(other, on: turn) {
        cut = min(cut ?? other.segment.start, other.segment.start)
      }

      guard let cutAt = cut, !turn.segment.words.isEmpty else {
        result.append(turn)
        continue
      }

      let head = turn.segment.words.filter { $0.start < cutAt }
      let tail = turn.segment.words.filter { $0.start >= cutAt }
      // Nothing to gain if the cut lands before the first word or after the
      // last — emit whole and let the intruder follow at its own time.
      guard let headEnd = head.last?.end, let tailStart = tail.first?.start else {
        result.append(turn)
        continue
      }

      let headSegment = slice(turn.segment, words: head, start: turn.segment.start, end: headEnd)
      let tailSegment = slice(turn.segment, words: tail, start: tailStart, end: turn.segment.end)
      result.append(retagging(turn, as: headSegment))
      insertByStart(&pending, retagging(turn, as: tailSegment))
    }
    return result
  }

  /// `turn` with a different underlying ``Segment`` (a split piece), keeping
  /// its source, speaker, and provenance flag.
  private static func retagging(_ turn: TranscriptSegment, as segment: Segment) -> TranscriptSegment
  {
    TranscriptSegment(
      source: turn.source, speaker: turn.speaker, segment: segment,
      sourceProvenance: turn.sourceProvenance)
  }

  /// Whether `other` is a different speaker who starts talking strictly
  /// inside `turn` (after its start, before its end) — i.e. a turn boundary
  /// that `turn` should be split at.
  private static func intrudes(_ other: TranscriptSegment, on turn: TranscriptSegment) -> Bool {
    other.speaker != turn.speaker
      && other.segment.start > turn.segment.start
      && other.segment.start < turn.segment.end
  }

  /// A sub-segment carrying a contiguous run of `words`; its text is
  /// synthesised from those words (a split piece has no authoritative text of
  /// its own), while segment-level `confidence` is carried through unchanged.
  private static func slice(
    _ segment: Segment, words: [WordTiming], start: Double, end: Double
  ) -> Segment {
    Segment(
      start: start,
      end: end,
      text: words.map(\.text).joined(separator: " "),
      words: words,
      confidence: segment.confidence)
  }

  /// Inserts `turn` into the ascending-by-start `pending` queue, after any
  /// equal-start entries so an intruder that starts at the same instant is
  /// still emitted before this re-queued remainder.
  private static func insertByStart(
    _ pending: inout [TranscriptSegment], _ turn: TranscriptSegment
  ) {
    var index = 0
    while index < pending.count && pending[index].segment.start <= turn.segment.start {
      index += 1
    }
    pending.insert(turn, at: index)
  }
}
