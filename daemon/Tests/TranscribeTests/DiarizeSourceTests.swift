import EarsCore
import EarsDataStore
import Testing

@testable import transcribe

/// A ``Diarizer`` that returns fixed spans (in the concatenated-buffer time it
/// is handed), so ``TranscribePipeline/diarizeSource`` can be tested without a
/// real model.
private struct FixedDiarizer: Diarizer {
  let info = DiarizerInfo(name: "fixed", version: "0")
  let spans: [SpeakerSpan]
  func load(_ options: LoadOptions) throws {}
  func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan] { spans }
}

@Suite("TranscribePipeline diarization helpers")
struct DiarizeSourceTests {
  private let start = Instant(secondsSinceEpoch: 1_784_284_200)

  private func oneSecondSlice(realOffset: Double) -> AudioSlice {
    AudioSlice(
      audio: AudioBuffer(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000),
      range: TimeRange(
        start: start.advanced(by: realOffset), end: start.advanced(by: realOffset + 1)))
  }

  @Test("only multi-speaker far-end sources are diarized")
  func shouldDiarizeSelectsFarEndSources() {
    #expect(TranscribePipeline.shouldDiarize(SourceID("mic")) == false)
    #expect(TranscribePipeline.shouldDiarize(SourceID("browser:meet:jane-a1b2")) == false)
    #expect(TranscribePipeline.shouldDiarize(SourceID("app:us.zoom.xos")))
    #expect(TranscribePipeline.shouldDiarize(SourceID("system")))
    #expect(TranscribePipeline.shouldDiarize(SourceID("device:AB12")))
  }

  @Test("spans are clipped to each slice and translated onto the range timeline")
  func diarizeSourceStitchesAndTranslates() throws {
    // Two 1s speech slices with a 4s VAD gap between them: slice A covers real
    // 0–1, slice B covers real 5–6. Concatenated, A is [0,1) and B is [1,2).
    let slices = [oneSecondSlice(realOffset: 0), oneSecondSlice(realOffset: 5)]
    // Diarizer output in concatenated time, including a span that straddles the
    // A/B boundary (which corresponds to the removed silence gap).
    let diarizer = FixedDiarizer(spans: [
      SpeakerSpan(start: 0, end: 0.5, speaker: "Speaker 1"),
      SpeakerSpan(start: 0.5, end: 1.5, speaker: "Speaker 2"),
      SpeakerSpan(start: 1.5, end: 2, speaker: "Speaker 1"),
    ])

    let spans = try TranscribePipeline.diarizeSource(
      slices: slices, requestedStart: start, diarizer: diarizer)

    // The straddling span is split at the gap: its A-half lands at real 0.5–1,
    // its B-half at real 5–5.5. Everything is on the requested-range timeline.
    #expect(
      spans == [
        SpeakerSpan(start: 0, end: 0.5, speaker: "Speaker 1"),
        SpeakerSpan(start: 0.5, end: 1, speaker: "Speaker 2"),
        SpeakerSpan(start: 5, end: 5.5, speaker: "Speaker 2"),
        SpeakerSpan(start: 5.5, end: 6, speaker: "Speaker 1"),
      ])
  }

  @Test("no slices yields no spans")
  func diarizeSourceEmpty() throws {
    let spans = try TranscribePipeline.diarizeSource(
      slices: [], requestedStart: start, diarizer: FixedDiarizer(spans: []))
    #expect(spans.isEmpty)
  }
}
