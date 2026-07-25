import EarsCore
import Foundation

/// Errors specific to ``SortformerDiarizerBackend`` itself (as opposed to
/// errors FluidAudio throws, which are propagated as-is).
public enum SortformerDiarizerError: Error, Sendable, Equatable {
  /// `diarize` was called before a successful `load`.
  case notLoaded
}

/// The native diarization backend (`docs/specs/model-interface.md`'s `Diarizer`
/// protocol): NVIDIA **Sortformer** via FluidAudio's Core ML/ANE pipeline. The
/// diarization sibling of ``EarsTranscribeKit``'s `ParakeetTranscriber`.
///
/// Named `…Backend` rather than `SortformerDiarizer` on purpose: FluidAudio
/// already exports a `SortformerDiarizer`, and a same-named type in this module
/// would shadow it everywhere in the module (Swift has no import aliasing). The
/// real FluidAudio calls are encapsulated in ``SortformerEngine`` (a
/// FluidAudio-only file); this file imports `EarsCore` and **not** FluidAudio,
/// so `Diarizer` here is unambiguously `EarsCore.Diarizer`.
///
/// - Conforms to ``Diarizer`` (the offline/batch pass). This first cut is
///   **offline-only** — `info.supportsStreaming` is `false` and it does not
///   conform to ``StreamingDiarizer``. The durable transcript reflects this
///   stabilised offline pass; the fast live pass (`--follow`) is the tracked
///   follow-up, which will add streaming over FluidAudio's `addAudio`/`process`.
/// - Every Core ML/ANE call is funneled through a shared ``ANEInferenceGate`` —
///   the same instance the ASR backend uses — per the spec's macOS 14 SIGBUS
///   requirement, since that contention is process-wide, not per-model.
///
/// ## The sync-protocol / async-SDK mismatch
///
/// `Diarizer.load` is synchronous `throws`, but FluidAudio's model download is
/// `async`. This shim bridges sync → async with the same blocking semaphore
/// (`blockingBridge`) and calling-context caveats as `ParakeetTranscriber`.
/// FluidAudio's `processComplete` is itself synchronous, so `diarize` only
/// crosses the bridge to await the ANE gate.
public final class SortformerDiarizerBackend: Diarizer, @unchecked Sendable {
  public private(set) var info: DiarizerInfo

  private let gate: ANEInferenceGate
  private let cacheDirectory: URL?
  private let engine = SortformerEngine()

  /// - Parameters:
  ///   - cacheDirectory: Where FluidAudio caches downloaded model weights;
  ///     `nil` uses FluidAudio's own default cache directory.
  ///   - gate: The shared ``ANEInferenceGate`` serializing ANE inference. Pass
  ///     the **same** instance used by the ASR backend so ASR and diarization
  ///     never run Core ML concurrently (the macOS 14 SIGBUS is process-wide).
  public init(
    cacheDirectory: URL? = nil,
    gate: ANEInferenceGate = ANEInferenceGate()
  ) {
    self.cacheDirectory = cacheDirectory
    self.gate = gate
    self.info = DiarizerInfo(
      name: "sortformer-fluidaudio",
      version: "sortformer-4spk",
      supportsStreaming: false
    )
  }

  public func load(_ options: LoadOptions) throws {
    let computeUnits = resolveComputeUnits(for: options.compute)
    let cache = cacheDirectory
    let engine = self.engine
    try blockingBridge {
      try await self.gate.run {
        try await engine.load(cacheDirectory: cache, computeUnits: computeUnits)
      }
    }
  }

  /// Batch-diarizes `audio` (expected mono 16 kHz — Sortformer's contract, the
  /// same feed the ASR path decodes). Each ``SpeakerSpan/speaker`` is
  /// `Speaker N` (1-based over Sortformer's 4 fixed slots); times are seconds
  /// relative to the start of `audio`.
  public func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan] {
    let engine = self.engine
    let samples = audio.samples
    let sampleRate = Double(audio.sampleRate)
    return try blockingBridge { () async throws -> [SpeakerSpan] in
      try await self.gate.run { () async throws -> [SpeakerSpan] in
        guard engine.isLoaded else { throw SortformerDiarizerError.notLoaded }
        return try engine.diarize(samples: samples, sampleRate: sampleRate)
          .map { raw in
            SpeakerSpan(
              start: raw.start,
              end: raw.end,
              speaker: "Speaker \(raw.speakerIndex + 1)")
          }
      }
    }
  }
}
