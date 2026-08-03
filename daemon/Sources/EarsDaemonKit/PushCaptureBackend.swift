import EarsCore
import EarsIPC

/// A capture backend whose buffers carry sender-side provenance.
///
/// `CaptureBackend`'s stream element is a plain ``AudioBuffer`` — a pure domain
/// value shared with the transcriber and diarizer — and stamping it with
/// transport metadata would push wire concerns into model code. Instead a
/// stamped backend keeps a FIFO alongside the buffer stream: one entry per
/// pushed buffer, in the same order, so ``takeStamp()`` called once per
/// consumed buffer stays aligned with it.
public protocol StampedCaptureBackend: AnyObject, Sendable {
  /// The stamp for the next buffer in stream order, or nil when the sender is
  /// an older client that emits legacy (unstamped) frames.
  func takeStamp() async -> IngestFrameStamp?
}

/// A ``CaptureBackend`` fed by explicit ``push(_:)`` calls instead of
/// pulling from real hardware — the "ingest push direction for socket-fed
/// sources" `CaptureBackend`'s own doc comment defers to Phase 6. One
/// instance per dynamically-created `browser:<label>` source; ``EarsDaemon``
/// owns its lifetime alongside the ``CaptureActor`` it backs.
///
/// An `actor` so concurrent ``push(_:)`` calls from the ingest WebSocket's
/// per-connection read loop can never race the stream's lifecycle.
public actor PushCaptureBackend: CaptureBackend, StampedCaptureBackend {
  public nonisolated let source: SourceID
  private var continuation: AsyncStream<AudioBuffer>.Continuation?
  /// One entry per yielded buffer, in stream order. Bounded by the same
  /// back-pressure the stream itself has; cleared on stop so a restarted
  /// stream never inherits the previous one's alignment.
  private var stamps: [IngestFrameStamp?] = []

  public init(source: SourceID) {
    self.source = source
  }

  public func start() async throws -> AsyncStream<AudioBuffer> {
    let (stream, continuation) = AsyncStream<AudioBuffer>.makeStream()
    self.continuation = continuation
    stamps.removeAll(keepingCapacity: true)
    return stream
  }

  public func stop() async {
    continuation?.finish()
    continuation = nil
    stamps.removeAll(keepingCapacity: false)
  }

  /// Feed one decoded buffer in. A no-op before ``start()``/after
  /// ``stop()`` — the buffer is simply dropped, matching a real backend
  /// producing nothing while not capturing.
  ///
  /// The stamp is enqueued before the buffer is yielded, so a consumer that
  /// takes one stamp per buffer always sees the matching entry.
  public func push(_ buffer: AudioBuffer, stamp: IngestFrameStamp? = nil) {
    guard let continuation else { return }
    stamps.append(stamp)
    continuation.yield(buffer)
  }

  public func takeStamp() async -> IngestFrameStamp? {
    guard !stamps.isEmpty else { return nil }
    return stamps.removeFirst()
  }
}
