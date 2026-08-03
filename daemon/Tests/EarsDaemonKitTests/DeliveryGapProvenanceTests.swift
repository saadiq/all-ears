import EarsCore
import EarsIPC
import Testing

@testable import EarsDaemonKit

/// `capture.delivery_gap` fires on any silence over 2s, which on Meet's
/// per-speaker streams is most of a call. The 2026-07-27 capture logged 395 of
/// them totalling 34% of the call with no way to tell a quiet speaker from a
/// dead extension. These cover the classification that closes that gap.
@Suite("delivery gap provenance")
struct DeliveryGapProvenanceTests {
  private let now = Instant(secondsSinceEpoch: 1_700_000_010)
  /// Epoch ms for `now`, so a stamp can be placed relative to it.
  private var nowMs: Double { 1_700_000_010 * 1000 }

  private func value(_ fields: [LogField], _ key: String) -> LogValue? {
    fields.first { $0.key == key }?.value
  }

  private func provenance(
    gapSeconds: Double, previousSentMsAgo: Double?, currentSentMsAgo: Double,
    previousSeq: UInt32 = 1, currentSeq: UInt32 = 2
  ) -> [LogField] {
    let previous = previousSentMsAgo.map {
      IngestFrameStamp(seq: previousSeq, sentAtEpochMs: nowMs - $0)
    }
    return CaptureActor.gapProvenance(
      gapSeconds: gapSeconds,
      from: previous,
      to: IngestFrameStamp(seq: currentSeq, sentAtEpochMs: nowMs - currentSentMsAgo),
      now: now)
  }

  @Test("a sender that was itself quiet for the gap is silence, not a stall")
  func silence() {
    // 5s gap; the sender's own clock shows 5s between the two frames.
    let fields = provenance(gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 0)
    #expect(value(fields, "cause") == .string("silence"))
    #expect(value(fields, "send_gap_ms") == .double(5000))
    #expect(value(fields, "seq_gap") == .int(0))
  }

  @Test("frames produced back-to-back but delivered late are a delivery stall")
  func deliveryStall() {
    // 5s observed gap, but the sender emitted these 20ms apart: the delay is
    // downstream of capture, not silence.
    let fields = provenance(gapSeconds: 5, previousSentMsAgo: 5020, currentSentMsAgo: 5000)
    #expect(value(fields, "cause") == .string("delivery-stall"))
    #expect(value(fields, "send_gap_ms") == .double(20))
  }

  @Test("a skipped sequence is reported as lost frames, outranking the timing verdict")
  func framesLost() {
    let fields = provenance(
      gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 0, previousSeq: 10, currentSeq: 15)
    #expect(value(fields, "cause") == .string("frames-lost"))
    #expect(value(fields, "seq_gap") == .int(4))
  }

  @Test("consecutive sequence numbers are not a gap")
  func consecutiveSeq() {
    let fields = provenance(
      gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 0, previousSeq: 7, currentSeq: 8)
    #expect(value(fields, "seq_gap") == .int(0))
    #expect(value(fields, "cause") == .string("silence"))
  }

  @Test("a sequence wrapping past 2^32 is not mistaken for a huge loss")
  func wrappingSeq() {
    let fields = provenance(
      gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 0,
      previousSeq: .max, currentSeq: 0)
    #expect(value(fields, "seq_gap") == .int(0))
    #expect(value(fields, "cause") == .string("silence"))
  }

  @Test("a sender seq restart (pipeline rebuild) is a fresh baseline, not billions of lost frames")
  func senderRestart() {
    // Meet rebuilt the participant's capture pipeline mid-session: seq is
    // per-pipeline-instance, so it starts over at 0 from an arbitrary
    // previous value. The naive wrapping delta would read ~4.29e9 lost.
    let fields = provenance(
      gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 0,
      previousSeq: 48_213, currentSeq: 0)
    #expect(value(fields, "cause") == .string("silence"))
    #expect(value(fields, "seq_gap") == .int(0))
    #expect(value(fields, "sender_restart") == .bool(true))
  }

  @Test("a wrap past 2^32 that also skipped frames still counts the loss")
  func wrappingSeqWithLoss() {
    // Wrapped slightly past 2^32 (not restarted near 0): 0xFFFFFFFF → 3
    // skipped seqs 0, 1, 2.
    let fields = provenance(
      gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 0,
      previousSeq: .max, currentSeq: 3)
    #expect(value(fields, "cause") == .string("frames-lost"))
    #expect(value(fields, "seq_gap") == .int(3))
    #expect(value(fields, "sender_restart") == nil)
  }

  @Test("a small backwards step is reordering, not a restart and not loss")
  func reorderedSeq() {
    let fields = provenance(
      gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 0,
      previousSeq: 10, currentSeq: 9)
    #expect(value(fields, "seq_gap") == .int(0))
    #expect(value(fields, "sender_restart") == nil)
    #expect(value(fields, "cause") == .string("silence"))
  }

  @Test("one-way delay is reported whenever a stamp is present")
  func oneWayDelay() {
    let fields = provenance(gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 250)
    #expect(value(fields, "one_way_ms") == .double(250))
  }

  @Test("a legacy client with no stamp is reported as unknown, never guessed at")
  func legacyClient() {
    let fields = CaptureActor.gapProvenance(gapSeconds: 5, from: nil, to: nil, now: now)
    #expect(value(fields, "cause") == .string("unknown"))
    #expect(value(fields, "send_gap_ms") == nil)
  }

  @Test("the first stamped frame of a stream has no predecessor to compare against")
  func firstFrame() {
    let fields = CaptureActor.gapProvenance(
      gapSeconds: 5, from: nil,
      to: IngestFrameStamp(seq: 1, sentAtEpochMs: nowMs), now: now)
    #expect(value(fields, "cause") == .string("unknown"))
    // Delay is still computable from one stamp, so it is still reported.
    #expect(value(fields, "one_way_ms") == .double(0))
  }

  @Test("the silence threshold is a majority of the gap, not an exact match")
  func partialSilence() {
    // Sender quiet for 3s of a 5s gap: over half, so silence dominates.
    #expect(
      value(provenance(gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 2000), "cause")
        == .string("silence"))
    // Quiet for only 1s of a 5s gap: the rest is delivery delay.
    #expect(
      value(provenance(gapSeconds: 5, previousSentMsAgo: 5000, currentSentMsAgo: 4000), "cause")
        == .string("delivery-stall"))
  }
}
