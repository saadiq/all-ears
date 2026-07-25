/// Optional capability: incremental (streaming) diarization for the fast live
/// pass, gated by `DiarizerInfo.supportsStreaming`.
///
/// Mirrors ``StreamingTranscriber`` exactly — the caller owns continuity
/// (speaker-slot / FIFO / cache state is explicit and passed `inout`), so the
/// diarization manager itself stays stateless across sources: one diarizer
/// serves many streams, each threading its own ``DiarizerState``. The durable
/// transcript reflects the stabilised *offline* pass (``Diarizer/diarize(_:)``);
/// this live pass is provisional and gets overwritten on finalization
/// (`docs/specs/model-interface.md`'s two-pass design).
public protocol StreamingDiarizer: Diarizer {
  /// Diarize the next block of frames, threading continuity through `state`.
  func step(_ frames: AudioBuffer, state: inout DiarizerState) throws -> [SpeakerSpan]
}
