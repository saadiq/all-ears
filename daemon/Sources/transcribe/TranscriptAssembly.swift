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
  /// protocol, out of scope for this pass). Precedence: reconciled speaker
  /// name (from `speakers`) → `mic` → "You" → descriptor label → raw id.
  ///
  /// Because the merge groups turns by this *resolved label* rather than by
  /// the raw source id, two source ids that resolve to the same label are
  /// coalesced into one speaker. That is what unifies a participant across a
  /// Meet identity upgrade: the roster's `[speakers]` map (attendee `source`
  /// -> `display_name`, threaded in by ``TranscribePipeline``) points both
  /// the pre- and post-upgrade sources at the same Meet display name, so they
  /// render under one consistent label instead of two.
  static func speakerLabel(
    for sourceID: SourceID, speakers: [String: String] = [:],
    sourceLabels: [String: String] = [:]
  ) -> String {
    if let name = speakers[sourceID.rawValue] { return name }
    if sourceID == SourceID("mic") { return "You" }
    if let label = sourceLabels[sourceID.rawValue], !label.isEmpty { return label }
    return sourceID.rawValue
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

  /// Builds the final document. Exactly one of `rangeRun` (the synthesized
  /// raw-range run identifier) and `session` (the session UUID) is normally
  /// non-`nil`; each renders as its own frontmatter line only when present.
  static func assemble(
    sourceIDs: [SourceID],
    transcriptions: [SourceTranscription],
    requested: TimeRange,
    rangeRun: String? = nil,
    session: String? = nil,
    title: String? = nil,
    started: Instant? = nil,
    attendees: [String] = [],
    warnings: [String] = [],
    speakers: [SessionSpeaker] = [],
    sourceLabels: [String: String] = [:],
    diarization: [SourceID: [SpeakerSpan]] = [:],
    diarizationBackend: String? = nil,
    model: TranscriptModelInfo,
    generated: Instant,
    speechSeconds: Double,
    audioStores: [TranscriptAudioStore] = [],
    backchannelMaxWords: Int = defaultBackchannelMaxWords
  ) -> TranscriptDocument {
    // Labelling wants a source → name lookup; the reconciler already
    // guarantees one name per source (its invariant 3), so first claimant
    // wins here purely defensively.
    var names: [String: String] = [:]
    for speaker in speakers where names[speaker.source.rawValue] == nil {
      names[speaker.source.rawValue] = speaker.name
    }
    var turns: [TranscriptSegment] = []
    for transcription in transcriptions {
      let base = speakerLabel(
        for: transcription.sourceID, speakers: names, sourceLabels: sourceLabels)
      let spans = diarization[transcription.sourceID] ?? []
      for segment in transcription.segments {
        turns.append(
          contentsOf: diarizedTurns(
            source: transcription.sourceID, base: base, segment: segment, spans: spans))
      }
    }
    // A turn with no words says nothing a reader can use, and the ASR emits
    // plenty of them — eleven of the first fifteen on the 2026-08-12 call. Drop
    // them before weaving so they cannot end a speaker's floor or host a
    // backchannel. They carry no words, so the word count is unaffected.
    let spoken = turns.filter {
      !$0.segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let ordered = weave(spoken, backchannelMaxWords: backchannelMaxWords)

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
      rangeRun: rangeRun,
      session: session,
      title: title,
      started: started,
      attendees: attendees,
      warnings: warnings,
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

    return TranscriptDocument(frontmatter: frontmatter, segments: ordered, speakers: speakers)
  }

  /// Longest an utterance can be and still count as a backchannel. Four words
  /// covers "Yeah.", "Right.", "Yeah. Yep.", "Oh that's interesting" while
  /// leaving a real interjection to stand as its own turn. A taste judgement,
  /// not a fact — hence a parameter, awaiting a config key.
  static let defaultBackchannelMaxWords: Int = 4

  /// Weaves every source's turns into one readable stream.
  ///
  /// The previous implementation split a turn at word boundaries wherever
  /// another speaker started talking inside it. That is faithful to the audio
  /// and unreadable as a document: on the 2026-08-12 call a mutual "nice to
  /// meet you" became ten one-word turns and neither sentence survived. Audio
  /// is a timeline; a transcript is a document, and a document is read one
  /// thing at a time.
  ///
  /// Two rules:
  ///
  /// 1. **A speaker holds the floor: nothing is ever split.** Turns are
  ///    emitted whole, ordered by start time. This is the entire fix for
  ///    shredding — the fragments existed *because* of splitting, so declining
  ///    to split restores them. Note it deliberately does NOT merge a
  ///    speaker's consecutive segments: an ASR pause is a paragraph break a
  ///    reader wants, and merging on a time threshold turns a one-hour
  ///    single-speaker recording into one unbroken block.
  /// 2. **Backchannels are demoted.** An utterance sitting entirely inside
  ///    another speaker's utterance, at most `backchannelMaxWords` long, is
  ///    flagged ``TranscriptSegment/isBackchannel``. It keeps its text and
  ///    timing — "did they agree?" is a real question to ask a transcript —
  ///    but the renderer attaches it to the turn it interrupted rather than
  ///    breaking that turn in two. Each one is hoisted to sit immediately
  ///    after its host, which is what keeps the Markdown round-trippable with
  ///    three or more speakers, where the host is not necessarily the previous
  ///    turn by start time.
  ///
  /// Because nothing is split or merged, every turn keeps its original
  /// ``Segment`` and its authoritative text, and the word count is identical
  /// to the pre-weave total.
  private static func weave(
    _ turns: [TranscriptSegment], backchannelMaxWords: Int
  ) -> [TranscriptSegment] {
    // Ascending by start, input order preserved on ties (stable) so equal-time
    // turns keep a deterministic, source-then-segment ordering.
    let ordered =
      turns
      .enumerated()
      .sorted {
        $0.element.segment.start != $1.element.segment.start
          ? $0.element.segment.start < $1.element.segment.start
          : $0.offset < $1.offset
      }
      .map { $0.element }
    return hoistBackchannels(ordered, maxWords: backchannelMaxWords)
  }

  /// Rule 2 — flag contained short utterances and place each one directly
  /// after the utterance hosting it.
  private static func hoistBackchannels(
    _ utterances: [TranscriptSegment], maxWords: Int
  ) -> [TranscriptSegment] {
    func length(_ turn: TranscriptSegment) -> Int {
      turn.segment.words.isEmpty
        ? turn.segment.text.split(whereSeparator: \.isWhitespace).count
        : turn.segment.words.count
    }

    // hostIndex[i] = index of the utterance that i is a backchannel inside.
    var hostIndex: [Int: Int] = [:]
    for (index, turn) in utterances.enumerated() where length(turn) <= maxWords {
      for (other, host) in utterances.enumerated()
      where other != index
        && host.speaker != turn.speaker
        && host.segment.start <= turn.segment.start
        && turn.segment.end <= host.segment.end
      {
        // Longest containing utterance wins, so a backchannel inside nested
        // spans attaches to the one actually holding the floor.
        if let existing = hostIndex[index] {
          let span = utterances[existing].segment.end - utterances[existing].segment.start
          if host.segment.end - host.segment.start <= span { continue }
        }
        hostIndex[index] = other
      }
    }

    var children: [Int: [Int]] = [:]
    for (child, host) in hostIndex.sorted(by: { $0.key < $1.key }) {
      children[host, default: []].append(child)
    }

    var result: [TranscriptSegment] = []
    for (index, turn) in utterances.enumerated() where hostIndex[index] == nil {
      result.append(turn)
      for child in children[index] ?? [] {
        var backchannel = utterances[child]
        backchannel.isBackchannel = true
        result.append(backchannel)
      }
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
