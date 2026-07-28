import Foundation
import Testing

@testable import EarsIPC

/// The wire contract shared with `browser/lib/protocol.ts`. The extension's own
/// suite covers the encoder; these cover the decoder, including the shapes a
/// buggy or truncating client could produce.
@Suite("IngestFrame")
struct IngestFrameTests {
  /// Mirrors `encodeBinaryFrame(streamId, pcm)` in the extension.
  private func legacyFrame(streamID: String, pcm: [UInt8]) -> [UInt8] {
    let id = Array(streamID.utf8)
    return [UInt8(id.count)] + id + pcm
  }

  /// Mirrors `encodeBinaryFrame(streamId, pcm, {seq, sentAt})`.
  private func extendedFrame(streamID: String, seq: UInt32, sentAt: Double, pcm: [UInt8]) -> [UInt8]
  {
    let id = Array(streamID.utf8)
    var out: [UInt8] = [0, IngestFrame.extendedVersion, UInt8(id.count)]
    out += id
    for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((seq >> UInt32(shift)) & 0xFF)) }
    let bits = sentAt.bitPattern
    for shift in stride(from: 0, to: 64, by: 8) {
      out.append(UInt8((bits >> UInt64(shift)) & 0xFF))
    }
    return out + pcm
  }

  @Test("parses a legacy frame, leaving the stamp absent")
  func legacy() throws {
    let frame = legacyFrame(streamID: "s7", pcm: [1, 2, 3, 4])
    let parsed = try #require(try? IngestFrame.parse(frame).get())
    #expect(parsed.streamID == "s7")
    #expect(Array(parsed.pcm) == [1, 2, 3, 4])
    #expect(parsed.seq == nil)
    #expect(parsed.sentAtEpochMs == nil)
    #expect(parsed.isStamped == false)
  }

  @Test("parses an extended frame's seq and send timestamp exactly")
  func extended() throws {
    let frame = extendedFrame(streamID: "s123", seq: 42, sentAt: 1_700_000_000_123, pcm: [9, 8])
    let parsed = try #require(try? IngestFrame.parse(frame).get())
    #expect(parsed.streamID == "s123")
    #expect(parsed.seq == 42)
    #expect(parsed.sentAtEpochMs == 1_700_000_000_123)
    #expect(Array(parsed.pcm) == [9, 8])
    #expect(parsed.isStamped)
  }

  @Test("reads unaligned seq/sentAt fields, whose offset depends on the stream-id length")
  func unalignedFields() throws {
    for id in ["a", "ab", "abc", "abcd", "abcde"] {
      let frame = extendedFrame(streamID: id, seq: 0xDEAD_BEEF, sentAt: 12345.5, pcm: [1])
      let parsed = try #require(try? IngestFrame.parse(frame).get())
      #expect(parsed.seq == 0xDEAD_BEEF)
      #expect(parsed.sentAtEpochMs == 12345.5)
    }
  }

  @Test("round-trips the maximum sequence value rather than overflowing")
  func maxSeq() throws {
    let frame = extendedFrame(streamID: "s1", seq: .max, sentAt: 1, pcm: [])
    let parsed = try #require(try? IngestFrame.parse(frame).get())
    #expect(parsed.seq == UInt32.max)
  }

  @Test("an empty payload is reported as empty, not as a malformed frame")
  func emptyPayload() {
    #expect(IngestFrame.parse([]) == .failure(.empty))
  }

  @Test("a legacy frame whose idLen runs past the end is rejected")
  func legacyTruncated() {
    #expect(IngestFrame.parse([9, 115, 55]) == .failure(.truncated))
  }

  @Test("an extended frame missing its stamp fields is rejected, not read out of bounds")
  func extendedTruncated() {
    #expect(IngestFrame.parse([0, IngestFrame.extendedVersion]) == .failure(.truncated))
    // Header claims a 2-byte id and promises 12 stamp bytes that aren't there.
    #expect(
      IngestFrame.parse([0, IngestFrame.extendedVersion, 2, 115, 55]) == .failure(.truncated))
  }

  @Test("an unknown extended version is rejected by version, so the error names the cause")
  func unknownVersion() {
    #expect(IngestFrame.parse([0, 99, 2, 115, 55]) == .failure(.unsupportedVersion(99)))
  }

  @Test("an extended frame declaring a zero-length stream id is rejected")
  func emptyStreamID() {
    #expect(
      IngestFrame.parse([0, IngestFrame.extendedVersion, 0] + [UInt8](repeating: 0, count: 12))
        == .failure(.emptyStreamID))
  }

  @Test("a zero first byte can only mean 'extended', never a legacy empty id")
  func discriminatorIsUnambiguous() throws {
    // This is the property the whole two-shape scheme rests on: the extension
    // refuses to encode an empty stream id, so 0 is free to be the marker.
    let frame = extendedFrame(streamID: "s1", seq: 1, sentAt: 2, pcm: [3])
    let parsed = try #require(try? IngestFrame.parse(frame).get())
    #expect(parsed.isStamped)
  }
}
