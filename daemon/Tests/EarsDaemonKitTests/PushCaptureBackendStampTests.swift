import EarsCore
import EarsIPC
import Testing

@testable import EarsDaemonKit

/// The stamp FIFO is what lets `CaptureActor` attribute a delivery gap without
/// pushing transport metadata into `AudioBuffer` (a pure domain value shared
/// with the transcriber and diarizer). Its correctness rests entirely on
/// staying aligned with the buffer stream, which is what these cover.
@Suite("PushCaptureBackend stamps")
struct PushCaptureBackendStampTests {
  private func buffer(_ value: Float) -> AudioBuffer {
    AudioBuffer(samples: [value], sampleRate: 16000)
  }

  @Test("stamps come back in push order, one per buffer")
  func fifoOrder() async throws {
    let backend = PushCaptureBackend(source: SourceID(rawValue: "browser:meet:a"))
    _ = try await backend.start()
    for seq in UInt32(1)...3 {
      await backend.push(buffer(0.1), stamp: IngestFrameStamp(seq: seq, sentAtEpochMs: Double(seq)))
    }
    for seq in UInt32(1)...3 {
      #expect(await backend.takeStamp()?.seq == seq)
    }
    #expect(await backend.takeStamp() == nil)
  }

  @Test("an unstamped (legacy) push still consumes a slot, keeping the queue aligned")
  func legacyPushKeepsAlignment() async throws {
    // If a legacy push enqueued nothing, the next stamped buffer's stamp would
    // be handed to the wrong buffer and every delay reading after it would be
    // attributed to the wrong frame.
    let backend = PushCaptureBackend(source: SourceID(rawValue: "browser:meet:a"))
    _ = try await backend.start()
    await backend.push(buffer(0.1))  // legacy
    await backend.push(buffer(0.2), stamp: IngestFrameStamp(seq: 9, sentAtEpochMs: 5))
    #expect(await backend.takeStamp() == nil)  // matches the legacy buffer
    #expect(await backend.takeStamp()?.seq == 9)
  }

  @Test("pushes before start() are dropped and enqueue nothing")
  func pushBeforeStart() async {
    let backend = PushCaptureBackend(source: SourceID(rawValue: "browser:meet:a"))
    await backend.push(buffer(0.1), stamp: IngestFrameStamp(seq: 1, sentAtEpochMs: 1))
    #expect(await backend.takeStamp() == nil)
  }

  @Test("a restart clears stale stamps rather than misaligning the new stream")
  func restartClears() async throws {
    let backend = PushCaptureBackend(source: SourceID(rawValue: "browser:meet:a"))
    _ = try await backend.start()
    await backend.push(buffer(0.1), stamp: IngestFrameStamp(seq: 1, sentAtEpochMs: 1))
    await backend.stop()
    _ = try await backend.start()
    #expect(await backend.takeStamp() == nil)
    await backend.push(buffer(0.2), stamp: IngestFrameStamp(seq: 99, sentAtEpochMs: 2))
    #expect(await backend.takeStamp()?.seq == 99)
  }

  @Test("buffers still reach the stream unchanged")
  func buffersStillFlow() async throws {
    let backend = PushCaptureBackend(source: SourceID(rawValue: "browser:meet:a"))
    let stream = try await backend.start()
    await backend.push(buffer(0.25), stamp: IngestFrameStamp(seq: 1, sentAtEpochMs: 1))
    await backend.stop()
    var received: [AudioBuffer] = []
    for await item in stream { received.append(item) }
    #expect(received == [buffer(0.25)])
  }
}
