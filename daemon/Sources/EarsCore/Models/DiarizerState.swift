/// Opaque, backend-owned continuity state carried inside ``DiarizerState``.
///
/// The diarization analogue of ``BackendDecoderState``: `EarsCore` knows
/// nothing about any concrete streaming-diarizer representation (Sortformer's
/// speaker cache / FIFO / Core ML arrays); a backend shim conforms a small
/// reference type and stashes it here. Class-bound so ``DiarizerState`` can
/// stay `Hashable` by comparing box *identity*.
public protocol BackendDiarizerState: AnyObject, Sendable {}

/// Explicit, caller-owned continuity state for streaming diarization.
///
/// Passed `inout` to ``StreamingDiarizer/step(_:state:)`` so the diarization
/// manager itself stays stateless across sources (the same pattern as
/// ``DecoderState`` for streaming ASR): one manager serves many sources, each
/// threading its own state.
///
/// The pure field (`framesConsumed`) is caller-visible bookkeeping; ``backend``
/// carries the real streaming-diarizer state, owned entirely by whichever
/// backend shim populated it (see ``BackendDiarizerState``). Start a fresh
/// stream with `DiarizerState()`; a state populated by one backend must not be
/// handed to a different backend (a shim finding a foreign box starts fresh
/// rather than misreading it).
///
/// - Important: Copying a `DiarizerState` does **not** snapshot the stream: the
///   copies *share* the backend box, so stepping one advances the other's
///   continuity too. One stream = one `DiarizerState` threaded through
///   sequential steps.
public struct DiarizerState: Sendable, Hashable {
  /// Number of audio frames consumed so far in this stream.
  public var framesConsumed: Int
  /// The backend shim's real streaming-diarizer state, or `nil` before the
  /// first `step` of a stream. Compared by identity for `Hashable`.
  public var backend: (any BackendDiarizerState)?

  public init(
    framesConsumed: Int = 0,
    backend: (any BackendDiarizerState)? = nil
  ) {
    self.framesConsumed = framesConsumed
    self.backend = backend
  }

  public static func == (lhs: DiarizerState, rhs: DiarizerState) -> Bool {
    lhs.framesConsumed == rhs.framesConsumed
      && lhs.backend.map { ObjectIdentifier($0) } == rhs.backend.map { ObjectIdentifier($0) }
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(framesConsumed)
    hasher.combine(backend.map { ObjectIdentifier($0) })
  }
}
