@preconcurrency import CoreML
import EarsCore
import FluidAudio
import Foundation

/// Errors specific to ``SortformerDiarizer`` itself (as opposed to errors
/// FluidAudio's diarizer throws, which are propagated as-is).
public enum SortformerDiarizerError: Error, Sendable, Equatable {
  /// `diarize` was called before a successful `load`.
  case notLoaded
}

/// The native diarization backend (`docs/specs/model-interface.md`'s `Diarizer`
/// protocol): NVIDIA **Sortformer** via FluidAudio's Core ML/ANE pipeline. The
/// exact sibling of ``EarsTranscribeKit``'s `ParakeetTranscriber`:
///
/// - Conforms to ``EarsCore/Diarizer`` (the offline/batch pass). This first cut
///   is **offline-only** — `info.supportsStreaming` is `false` and it does not
///   conform to ``StreamingDiarizer``. The durable transcript reflects this
///   stabilised offline pass; the fast live pass (`--follow`) is deferred to a
///   follow-up (the two-pass design in the spec), which will add
///   ``StreamingDiarizer`` conformance over FluidAudio's `addAudio`/`process`
///   streaming API.
/// - Every real Core ML/ANE call (model load, `processComplete` inference) is
///   funneled through a shared ``ANEInferenceGate`` — the same instance the ASR
///   backend uses — per the spec's macOS 14 SIGBUS-avoidance requirement, since
///   that contention is process-wide, not per-model.
/// - Only this file (and its `EarsDiarizeKit` sibling) touches FluidAudio's
///   diarizer API, keeping the dependency behind the protocol seam.
///
/// ## Name disambiguation
///
/// FluidAudio also exports a concrete `SortformerDiarizer` and a `Diarizer`
/// protocol. Within this file the shim's own name shadows FluidAudio's, so the
/// FluidAudio engine is referred to as `FluidAudio.SortformerDiarizer` and the
/// EarsCore seam as `EarsCore.Diarizer` throughout.
///
/// ## The sync-protocol / async-SDK mismatch
///
/// `Diarizer.load` is synchronous `throws`, but FluidAudio's
/// `SortformerModels.loadFromHuggingFace` is `async` (it awaits a network
/// download + Core ML compile). This shim bridges sync → async with the same
/// blocking semaphore (`blockingBridge`) and calling-context caveats as
/// `ParakeetTranscriber`. FluidAudio's `processComplete` is itself synchronous,
/// so `diarize` only crosses the bridge to await the ANE gate.
public final class SortformerDiarizer: EarsCore.Diarizer, @unchecked Sendable {
  public private(set) var info: DiarizerInfo

  private let gate: ANEInferenceGate
  private let cacheDirectory: URL?
  private let box = EngineBox()

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

  /// Downloads (if needed) and loads the Sortformer Core ML models, then wires
  /// up FluidAudio's `SortformerDiarizer`. The download and Core ML load both
  /// run through ``ANEInferenceGate``.
  public func load(_ options: LoadOptions) throws {
    let computeUnits = resolveComputeUnits(for: options.compute)
    let cache = cacheDirectory
    let box = self.box
    try blockingBridge {
      try await self.gate.run {
        let models = try await FluidAudio.SortformerModels.loadFromHuggingFace(
          config: .default,
          cacheDirectory: cache,
          computeUnits: computeUnits
        )
        let engine = FluidAudio.SortformerDiarizer()
        engine.initialize(models: models)
        box.engine = engine
      }
    }
  }

  /// Batch-diarizes `audio` (expected mono 16 kHz — Sortformer's contract, the
  /// same feed the ASR path decodes) into speaker spans. Each
  /// ``SpeakerSpan/speaker`` is `Speaker N` (1-based over Sortformer's 4 fixed
  /// slots); times are seconds relative to the start of `audio`, matching the
  /// convention the pipeline shifts onto the shared timeline.
  ///
  /// `reset()` is called first so speaker slots do not carry over between
  /// sources when one shim instance diarizes several sources in a run.
  public func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan] {
    let box = self.box
    let samples = audio.samples
    let sampleRate = Double(audio.sampleRate)
    return try blockingBridge { () async throws -> [SpeakerSpan] in
      try await self.gate.run { () async throws -> [SpeakerSpan] in
        guard let engine = box.engine else { throw SortformerDiarizerError.notLoaded }
        engine.reset()
        let timeline = try engine.processComplete(
          samples,
          sourceSampleRate: sampleRate,
          keepingEnrolledSpeakers: nil,
          finalizeOnCompletion: true,
          progressCallback: nil
        )
        return
          timeline
          .finalizedSegments
          .sorted { $0.startTime < $1.startTime }
          .map { segment in
            SpeakerSpan(
              start: Double(segment.startTime),
              end: Double(segment.endTime),
              speaker: "Speaker \(segment.speakerIndex + 1)"
            )
          }
      }
    }
  }
}

/// Holds the loaded FluidAudio engine between `load` and `diarize`.
///
/// FluidAudio's `SortformerDiarizer` is a plain (non-`Sendable`) class guarding
/// its own state with `NSLock`. `@unchecked Sendable` is sound here because
/// access is fully serialized: `load` happens-before any `diarize`, and every
/// touch of `engine` occurs inside the shared ``ANEInferenceGate`` (single
/// in-flight call), so there is never concurrent access to the boxed engine —
/// the same discipline `ParakeetDecoderState`'s box relies on.
private final class EngineBox: @unchecked Sendable {
  var engine: FluidAudio.SortformerDiarizer?
}
