@preconcurrency import CoreML
import FluidAudio
import Foundation

/// A speaker span as FluidAudio's Sortformer reports it, in the diarized
/// buffer's own time. A plain value type carrying **no FluidAudio types**, so
/// the `EarsCore`-facing shim can consume it without `import FluidAudio`.
struct SortformerRawSpan: Sendable {
  let start: Double
  let end: Double
  let speakerIndex: Int
}

/// Thin wrapper over FluidAudio's Sortformer diarizer, deliberately isolated to
/// this **FluidAudio-only** file (no `import EarsCore`).
///
/// FluidAudio exports both a `Diarizer` protocol and a concrete
/// `SortformerDiarizer`, whose names collide with `EarsCore.Diarizer` and the
/// shim's own type. Swift has no `import X as Y`, and module-qualification does
/// not help: `FluidAudio.SortformerDiarizer` resolves to a *member* of
/// FluidAudio's empty `FluidAudio` namespace struct, not the module type. The
/// only robust disambiguation is to keep the two modules' name spaces in
/// separate files — FluidAudio's names live here; `EarsCore`'s live in
/// `SortformerDiarizerBackend.swift`, which does not import FluidAudio.
final class SortformerEngine: @unchecked Sendable {
  private var engine: SortformerDiarizer?

  var isLoaded: Bool { engine != nil }

  /// Downloads (if needed) and loads the Sortformer Core ML models. `async`
  /// because FluidAudio's `loadFromHuggingFace` awaits a network download +
  /// Core ML compile.
  func load(cacheDirectory: URL?, computeUnits: MLComputeUnits) async throws {
    let models = try await SortformerModels.loadFromHuggingFace(
      config: .default,
      cacheDirectory: cacheDirectory,
      computeUnits: computeUnits
    )
    let engine = SortformerDiarizer()
    engine.initialize(models: models)
    self.engine = engine
  }

  /// Batch-diarizes `samples` (mono 16 kHz) in one call, returning speaker
  /// spans sorted by start time. `reset()` first so speaker slots do not carry
  /// over between sources when one instance diarizes several sources in a run.
  func diarize(samples: [Float], sampleRate: Double) throws -> [SortformerRawSpan] {
    guard let engine else { return [] }
    engine.reset()
    let timeline = try engine.processComplete(
      samples,
      sourceSampleRate: sampleRate,
      keepingEnrolledSpeakers: nil,
      finalizeOnCompletion: true,
      progressCallback: nil
    )
    // Built with an explicit loop rather than a chained `.sorted{}.map{}`:
    // the chained form pushed the Swift type-checker past its time budget
    // ("unable to type-check this expression in reasonable time").
    let segments = timeline.finalizedSegments
    var spans: [SortformerRawSpan] = []
    spans.reserveCapacity(segments.count)
    for segment in segments {
      let start = Double(segment.startTime)
      let end = Double(segment.endTime)
      spans.append(
        SortformerRawSpan(start: start, end: end, speakerIndex: segment.speakerIndex))
    }
    spans.sort { $0.start < $1.start }
    return spans
  }
}
