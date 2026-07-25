/// The diarization backend seam: a separate, optional stage that assigns stable
/// speaker labels within a stream over a time range.
///
/// Channel-of-origin (the source) is the *primary* label; the diarizer only
/// *refines* a multi-speaker source into `Speaker N` and never overrides source
/// attribution. Transcribed from `docs/specs/model-interface.md`.
///
/// Capability-by-protocol, mirroring ``Transcriber``: this small base protocol
/// is the offline (batch) pass every diarizer provides, layered with the
/// optional ``StreamingDiarizer`` capability a backend opts into for the fast
/// live pass. The pipeline reads ``DiarizerInfo/supportsStreaming`` and
/// `as?`-casts to ``StreamingDiarizer`` rather than switching on a backend name.
///
/// Refines `Sendable` for the same actor-boundary reasons as ``Transcriber``.
public protocol Diarizer: Sendable {
  var info: DiarizerInfo { get }

  /// Load weights and pick the compute unit (ANE/GPU/CPU). Mirrors
  /// ``Transcriber/load(_:)`` and reuses the same backend-agnostic
  /// ``LoadOptions`` — a diarizer needs the same download/compile/compute
  /// selection an ASR backend does.
  func load(_ options: LoadOptions) throws

  /// Assign stable speaker labels to a stream's audio over its range (the
  /// offline/batch pass whose output the durable transcript reflects).
  func diarize(_ audio: AudioBuffer) throws -> [SpeakerSpan]
}
