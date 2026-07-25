import EarsCore
import Testing

@testable import transcribe

@Suite("TranscriptAssembly")
struct TranscriptAssemblyTests {
  private let start = Instant(secondsSinceEpoch: 1_784_284_200)

  private var requested: TimeRange { TimeRange(start: start, end: start.advanced(by: 30)) }

  private var model: TranscriptModelInfo {
    TranscriptModelInfo(name: "parakeet", backend: "fluidaudio", version: "0.x")
  }

  @Test("mic maps to the You speaker label")
  func micMapsToYou() {
    #expect(TranscriptAssembly.speakerLabel(for: SourceID("mic")) == "You")
  }

  @Test("a non-mic source is labelled with its own raw source id")
  func nonMicUsesRawSourceID() {
    #expect(
      TranscriptAssembly.speakerLabel(for: SourceID("app:us.zoom.xos")) == "app:us.zoom.xos")
  }

  @Test("segments from multiple sources are merged and ordered by start time")
  func mergesAndOrdersAcrossSources() {
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [
        Segment(start: 10, end: 12, text: "second"),
        Segment(start: 0, end: 2, text: "first"),
      ])
    let zoom = SourceTranscription(
      sourceID: "app:us.zoom.xos",
      segments: [
        Segment(start: 5, end: 7, text: "middle")
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic"), SourceID("app:us.zoom.xos")],
      transcriptions: [mic, zoom],
      requested: requested,
      sessionIdentifier: "2026-07-17T10-30-00Z_mic",
      model: model,
      generated: start.advanced(by: 40),
      speechSeconds: 6
    )

    #expect(document.segments.map(\.segment.text) == ["first", "middle", "second"])
    #expect(document.segments.map(\.speaker) == ["You", "app:us.zoom.xos", "You"])
  }

  @Test("a mid-turn reply interleaves inside a longer overlapping segment")
  func interleavesOverlappingWordTimedSegments() {
    // The guest speaks one long, continuous, word-timed turn; the mic
    // interjects twice *during* it. Ordering by segment.start alone would
    // emit the whole guest turn first and bury both replies after it.
    let guest = SourceTranscription(
      sourceID: "app:us.zoom.xos",
      segments: [
        Segment(
          start: 0, end: 12, text: "so as I was saying the plan is basically",
          words: [
            WordTiming(text: "so", start: 0, end: 1),
            WordTiming(text: "as", start: 1, end: 2),
            WordTiming(text: "I", start: 2, end: 3),
            WordTiming(text: "was", start: 3, end: 4),
            WordTiming(text: "saying", start: 4, end: 5),
            WordTiming(text: "the", start: 6, end: 7),
            WordTiming(text: "plan", start: 7, end: 8),
            WordTiming(text: "is", start: 9, end: 10),
            WordTiming(text: "basically", start: 10, end: 12),
          ])
      ])
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [
        Segment(
          start: 5, end: 6, text: "right",
          words: [WordTiming(text: "right", start: 5, end: 6)]),
        Segment(
          start: 8, end: 9, text: "makes sense",
          words: [
            WordTiming(text: "makes", start: 8, end: 8.5),
            WordTiming(text: "sense", start: 8.5, end: 9),
          ]),
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("app:us.zoom.xos"), SourceID("mic")],
      transcriptions: [guest, mic],
      requested: requested,
      sessionIdentifier: "id",
      model: model,
      generated: start,
      speechSeconds: 12
    )

    // The guest turn is split around each reply, and the replies land at their
    // own timestamps — a woven conversation, not two monolithic blocks.
    #expect(
      document.segments.map(\.speaker) == [
        "app:us.zoom.xos", "You", "app:us.zoom.xos", "You", "app:us.zoom.xos",
      ])
    #expect(
      document.segments.map(\.segment.text) == [
        "so as I was saying", "right", "the plan", "makes sense", "is basically",
      ])
    // Displayed segments are non-decreasing by start across the whole file.
    let starts = document.segments.map(\.segment.start)
    #expect(starts == starts.sorted())
    #expect(starts == [0, 5, 6, 8, 9])
    // No words are lost or duplicated by the split.
    #expect(document.frontmatter.wordCount == 12)
  }

  @Test("a single word-timed source is not fragmented (byte-identical turns)")
  func singleSourceIsNotSplit() {
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [
        Segment(
          start: 0, end: 2, text: "hello there",
          words: [
            WordTiming(text: "hello", start: 0, end: 1),
            WordTiming(text: "there", start: 1, end: 2),
          ]),
        Segment(
          start: 3, end: 5, text: "how are you",
          words: [
            WordTiming(text: "how", start: 3, end: 3.5),
            WordTiming(text: "are", start: 3.5, end: 4),
            WordTiming(text: "you", start: 4, end: 5),
          ]),
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic")],
      transcriptions: [mic],
      requested: requested,
      sessionIdentifier: "id",
      model: model,
      generated: start,
      speechSeconds: 4
    )

    // One turn per original segment, original text preserved verbatim.
    #expect(document.segments.map(\.segment.text) == ["hello there", "how are you"])
    #expect(document.segments.map(\.speaker) == ["You", "You"])
  }

  @Test("two source labels for one upgraded participant coalesce to one speaker")
  func coalescesUpgradedParticipantLabels() {
    // Same person, two source ids across a Meet identity upgrade. The roster's
    // [speakers] map points both at the same display name, so they render as
    // one speaker and never split each other.
    let speakers = [
      "browser:meet:speaker-1": "Priya",
      "browser:meet:spaces-x769r-devices-261": "Priya",
    ]
    let early = SourceTranscription(
      sourceID: "browser:meet:speaker-1",
      segments: [
        Segment(
          start: 0, end: 2, text: "before the upgrade",
          words: [
            WordTiming(text: "before", start: 0, end: 1),
            WordTiming(text: "the", start: 1, end: 1.5),
            WordTiming(text: "upgrade", start: 1.5, end: 2),
          ])
      ])
    let late = SourceTranscription(
      sourceID: "browser:meet:spaces-x769r-devices-261",
      segments: [
        Segment(
          start: 3, end: 5, text: "after the upgrade",
          words: [
            WordTiming(text: "after", start: 3, end: 4),
            WordTiming(text: "the", start: 4, end: 4.5),
            WordTiming(text: "upgrade", start: 4.5, end: 5),
          ])
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [
        SourceID("browser:meet:speaker-1"),
        SourceID("browser:meet:spaces-x769r-devices-261"),
      ],
      transcriptions: [early, late],
      requested: requested,
      sessionIdentifier: "id",
      speakers: speakers,
      model: model,
      generated: start,
      speechSeconds: 4
    )

    #expect(document.segments.map(\.speaker) == ["Priya", "Priya"])
    #expect(document.segments.map(\.segment.text) == ["before the upgrade", "after the upgrade"])
  }

  @Test("word count sums split text words when a segment has no word timings")
  func wordCountFromTextWhenNoWordTimings() {
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [Segment(start: 0, end: 2, text: "hello there world")])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic")],
      transcriptions: [mic],
      requested: requested,
      sessionIdentifier: "id",
      model: model,
      generated: start,
      speechSeconds: 2
    )

    #expect(document.frontmatter.wordCount == 3)
  }

  @Test("word count uses word timings when a segment has them, not the text split")
  func wordCountFromWordTimingsWhenPresent() {
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [
        Segment(
          start: 0, end: 2, text: "hello there",
          words: [
            WordTiming(text: "hello", start: 0, end: 1),
            WordTiming(text: "there", start: 1, end: 2),
          ])
      ])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic")],
      transcriptions: [mic],
      requested: requested,
      sessionIdentifier: "id",
      model: model,
      generated: start,
      speechSeconds: 2
    )

    #expect(document.frontmatter.wordCount == 2)
  }

  // MARK: - Diarization refinement

  @Test("refinedLabel appends the covering span's Speaker N to the base label")
  func refinedLabelUsesCoveringSpan() {
    let spans = [
      SpeakerSpan(start: 0, end: 5, speaker: "Speaker 1"),
      SpeakerSpan(start: 5, end: 10, speaker: "Speaker 2"),
    ]
    // Midpoint 3 falls in Speaker 1's span; midpoint 7 in Speaker 2's.
    #expect(
      TranscriptAssembly.refinedLabel(
        base: "app:us.zoom.xos", segment: Segment(start: 2, end: 4, text: "a"), spans: spans)
        == "app:us.zoom.xos · Speaker 1")
    #expect(
      TranscriptAssembly.refinedLabel(
        base: "app:us.zoom.xos", segment: Segment(start: 6, end: 8, text: "b"), spans: spans)
        == "app:us.zoom.xos · Speaker 2")
  }

  @Test("refinedLabel returns the base label unchanged when there are no spans")
  func refinedLabelNoSpansIsBase() {
    #expect(
      TranscriptAssembly.refinedLabel(
        base: "You", segment: Segment(start: 0, end: 2, text: "hi"), spans: [])
        == "You")
  }

  @Test("refinedLabel falls back to the maximum-overlap span when none covers the midpoint")
  func refinedLabelMaxOverlapFallback() {
    // Segment 0–10 has midpoint 5, which no span covers (there is a gap at 5);
    // it overlaps Speaker 2 (4–4.9 → 0.9s) more than Speaker 1 (0–4 → 4s)? No:
    // Speaker 1 overlap is 4s, Speaker 2 overlap is 0.9s, so Speaker 1 wins.
    let spans = [
      SpeakerSpan(start: 0, end: 4, speaker: "Speaker 1"),
      SpeakerSpan(start: 4, end: 4.9, speaker: "Speaker 2"),
    ]
    #expect(
      TranscriptAssembly.refinedLabel(
        base: "system", segment: Segment(start: 0, end: 10, text: "x"), spans: spans)
        == "system · Speaker 1")
  }

  // MARK: - Per-speaker segment splitting (diarizedTurns)

  /// A word-timed segment: one word per second, text = index, so a split's
  /// piece boundaries are easy to read off the word list.
  private func wordTimedSegment(words: [(String, Double, Double)]) -> Segment {
    Segment(
      start: words.first?.1 ?? 0,
      end: words.last?.2 ?? 0,
      text: words.map(\.0).joined(separator: " "),
      words: words.map { WordTiming(text: $0.0, start: $0.1, end: $0.2) })
  }

  @Test("a single word-timed segment is split into one turn per speaker run")
  func diarizedTurnsSplitsOneSegmentAcrossSpeakers() {
    // Six words, 0–6s; Sortformer says 0–2 is Speaker 1, 2–4 Speaker 2, 4–6
    // Speaker 1 again. This is the file-input bug: one whole-file ASR segment
    // that must fan out into three speaker turns instead of collapsing to one.
    let segment = wordTimedSegment(words: [
      ("w0", 0, 1), ("w1", 1, 2), ("w2", 2, 3), ("w3", 3, 4), ("w4", 4, 5), ("w5", 5, 6),
    ])
    let spans = [
      SpeakerSpan(start: 0, end: 2, speaker: "Speaker 1"),
      SpeakerSpan(start: 2, end: 4, speaker: "Speaker 2"),
      SpeakerSpan(start: 4, end: 6, speaker: "Speaker 1"),
    ]

    let turns = TranscriptAssembly.diarizedTurns(
      source: "Dipanshu", base: "Dipanshu", segment: segment, spans: spans)

    #expect(
      turns.map(\.speaker) == [
        "Dipanshu · Speaker 1", "Dipanshu · Speaker 2", "Dipanshu · Speaker 1",
      ])
    #expect(turns.map(\.segment.text) == ["w0 w1", "w2 w3", "w4 w5"])
    // The split covers exactly the segment's own bounds, edge to edge.
    #expect(turns.first?.segment.start == 0)
    #expect(turns.last?.segment.end == 6)
    // No word is lost across the split.
    #expect(turns.flatMap(\.segment.words).count == segment.words.count)
  }

  @Test("a word in a gap between spans folds into the current speaker's turn")
  func diarizedTurnsFoldsGapWords() {
    // Word w2 (2–3s) lands in a silence gap the spans don't cover; it must join
    // Speaker 1's ongoing turn rather than break out as a bare, speaker-less
    // one-word fragment.
    let segment = wordTimedSegment(words: [
      ("w0", 0, 1), ("w1", 1, 2), ("w2", 2, 3), ("w3", 3, 4),
    ])
    let spans = [
      SpeakerSpan(start: 0, end: 2, speaker: "Speaker 1"),
      SpeakerSpan(start: 3, end: 4, speaker: "Speaker 1"),
    ]

    let turns = TranscriptAssembly.diarizedTurns(
      source: "Dipanshu", base: "Dipanshu", segment: segment, spans: spans)

    #expect(turns.count == 1)
    #expect(turns.first?.speaker == "Dipanshu · Speaker 1")
    #expect(turns.first?.segment.text == "w0 w1 w2 w3")
  }

  @Test("a single-speaker segment keeps its original authoritative text")
  func diarizedTurnsSingleSpeakerKeepsSegment() {
    // Every word resolves to Speaker 2, so the whole segment stays one turn and
    // keeps its own `text` (not text re-joined from words).
    let segment = Segment(
      start: 0, end: 2, text: "hello, world!",
      words: [
        WordTiming(text: "hello", start: 0, end: 1), WordTiming(text: "world", start: 1, end: 2),
      ])
    let spans = [SpeakerSpan(start: 0, end: 2, speaker: "Speaker 2")]

    let turns = TranscriptAssembly.diarizedTurns(
      source: "call", base: "call", segment: segment, spans: spans)

    #expect(turns.count == 1)
    #expect(turns.first?.speaker == "call · Speaker 2")
    #expect(turns.first?.segment.text == "hello, world!")
  }

  @Test("a wordless segment cannot be split and falls back to the midpoint label")
  func diarizedTurnsWordlessFallsBackToMidpoint() {
    // No word timings ⇒ no boundaries to cut on ⇒ one whole turn, labelled by
    // the segment midpoint exactly as refinedLabel would.
    let segment = Segment(start: 0, end: 6, text: "a whole wordless block")
    let spans = [
      SpeakerSpan(start: 0, end: 2, speaker: "Speaker 1"),
      SpeakerSpan(start: 2, end: 6, speaker: "Speaker 2"),
    ]

    let turns = TranscriptAssembly.diarizedTurns(
      source: "Dipanshu", base: "Dipanshu", segment: segment, spans: spans)

    #expect(turns.count == 1)
    #expect(turns.first?.speaker == "Dipanshu · Speaker 2")
    #expect(turns.first?.segment.text == "a whole wordless block")
  }

  @Test("no spans leaves a word-timed segment as one unchanged base-labelled turn")
  func diarizedTurnsNoSpansIsInert() {
    let segment = wordTimedSegment(words: [("hi", 0, 1), ("there", 1, 2)])

    let turns = TranscriptAssembly.diarizedTurns(
      source: "mic", base: "You", segment: segment, spans: [])

    #expect(turns.count == 1)
    #expect(turns.first?.speaker == "You")
    #expect(turns.first?.segment.text == "hi there")
  }

  @Test("diarization refines a far-end source's turns while the mic is untouched")
  func diarizationRefinesFarEndNotMic() {
    let zoom = SourceTranscription(
      sourceID: "app:us.zoom.xos",
      segments: [
        Segment(start: 0, end: 2, text: "hello"),
        Segment(start: 6, end: 8, text: "goodbye"),
      ])
    let mic = SourceTranscription(
      sourceID: "mic",
      segments: [Segment(start: 3, end: 4, text: "ok")])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("app:us.zoom.xos"), SourceID("mic")],
      transcriptions: [zoom, mic],
      requested: requested,
      sessionIdentifier: "id",
      diarization: [
        SourceID("app:us.zoom.xos"): [
          SpeakerSpan(start: 0, end: 3, speaker: "Speaker 1"),
          SpeakerSpan(start: 5, end: 9, speaker: "Speaker 2"),
        ]
      ],
      diarizationBackend: "sortformer-fluidaudio",
      model: model,
      generated: start,
      speechSeconds: 5
    )

    // Ordered by start: zoom@0 (Speaker 1), mic@3 (untouched You), zoom@6 (Speaker 2).
    #expect(
      document.segments.map(\.speaker) == [
        "app:us.zoom.xos · Speaker 1", "You", "app:us.zoom.xos · Speaker 2",
      ])
    #expect(document.frontmatter.diarization.enabled)
    #expect(document.frontmatter.diarization.backend == "sortformer-fluidaudio")
  }

  @Test("empty diarization leaves labels and frontmatter exactly as the non-diarized path")
  func emptyDiarizationIsInert() {
    let zoom = SourceTranscription(
      sourceID: "app:us.zoom.xos",
      segments: [Segment(start: 0, end: 2, text: "hello")])

    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("app:us.zoom.xos")],
      transcriptions: [zoom],
      requested: requested,
      sessionIdentifier: "id",
      diarization: [:],
      diarizationBackend: "sortformer-fluidaudio",
      model: model,
      generated: start,
      speechSeconds: 2
    )

    #expect(document.segments.map(\.speaker) == ["app:us.zoom.xos"])
    // No spans ⇒ disabled, and backend omitted even though a name was passed.
    #expect(document.frontmatter.diarization == TranscriptDiarizationInfo(enabled: false))
  }

  @Test("frontmatter fields carry through unchanged from the given parameters")
  func frontmatterFieldsCarryThrough() {
    let document = TranscriptAssembly.assemble(
      sourceIDs: [SourceID("mic")],
      transcriptions: [],
      requested: requested,
      sessionIdentifier: "2026-07-17T10-30-00Z_mic",
      model: model,
      generated: start.advanced(by: 40),
      speechSeconds: 12
    )

    #expect(document.frontmatter.schema == 1)
    #expect(document.frontmatter.kind == .transcript)
    #expect(document.frontmatter.session == "2026-07-17T10-30-00Z_mic")
    #expect(document.frontmatter.sources == [SourceID("mic")])
    #expect(document.frontmatter.range == requested)
    #expect(document.frontmatter.model == model)
    #expect(document.frontmatter.diarization == TranscriptDiarizationInfo(enabled: false))
    #expect(document.frontmatter.generated == start.advanced(by: 40))
    #expect(document.frontmatter.durationSeconds == 30)
    #expect(document.frontmatter.speechSeconds == 12)
    #expect(document.frontmatter.vocab.isEmpty)
  }
}
