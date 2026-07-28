/// Parser for the binary PCM frames the browser extension streams over
/// `ws://127.0.0.1:<port>/ingest`.
///
/// Two wire shapes, discriminated by the first byte:
///
///     legacy:   [u8 idLen>0][stream_id ASCII][pcm_s16le]
///     extended: [0x00][u8 ver=1][u8 idLen][stream_id ASCII][u32le seq][f64le sentAt][pcm_s16le]
///
/// A zero first byte cannot occur in the legacy shape — stream ids are never
/// empty — which is what makes it a safe discriminator. Both are accepted, so a
/// daemon upgraded ahead of the extension keeps ingesting.
///
/// The extended shape exists because the legacy one carried no timestamps at
/// all. Without them the daemon cannot tell a participant who simply stopped
/// talking from an extension whose audio path has died: both look like "no
/// frames arrived". `seq` and `sentAt` make that distinction observable — see
/// `CaptureActor.reanchorAfterDeliveryGap`.
public struct IngestFrame: Sendable, Equatable {
  public let streamID: String
  public let pcm: ArraySlice<UInt8>
  /// Monotonic per-stream counter, wrapping at 2^32. Nil on legacy frames.
  public let seq: UInt32?
  /// Browser-side send time, epoch milliseconds. Nil on legacy frames.
  public let sentAtEpochMs: Double?

  public var isStamped: Bool { seq != nil }

  public enum ParseError: Error, Equatable, Sendable {
    case empty
    case truncated
    case unsupportedVersion(UInt8)
    case emptyStreamID
    case nonASCIIStreamID
  }

  /// The one extended-frame version this build understands.
  public static let extendedVersion: UInt8 = 1

  public static func parse(_ payload: [UInt8]) -> Result<IngestFrame, ParseError> {
    guard let first = payload.first else { return .failure(.empty) }

    if first != 0 {
      let idLength = Int(first)
      guard payload.count >= 1 + idLength else { return .failure(.truncated) }
      guard let id = String(bytes: payload[1..<(1 + idLength)], encoding: .ascii) else {
        return .failure(.nonASCIIStreamID)
      }
      return .success(
        IngestFrame(streamID: id, pcm: payload[(1 + idLength)...], seq: nil, sentAtEpochMs: nil))
    }

    guard payload.count >= 3 else { return .failure(.truncated) }
    let version = payload[1]
    guard version == extendedVersion else { return .failure(.unsupportedVersion(version)) }
    let idLength = Int(payload[2])
    guard idLength > 0 else { return .failure(.emptyStreamID) }
    let headerLength = 3 + idLength + 12  // u32 seq + f64 sentAt
    guard payload.count >= headerLength else { return .failure(.truncated) }
    guard let id = String(bytes: payload[3..<(3 + idLength)], encoding: .ascii) else {
      return .failure(.nonASCIIStreamID)
    }
    let seq = readUInt32LE(payload, at: 3 + idLength)
    let sentAt = Double(bitPattern: readUInt64LE(payload, at: 3 + idLength + 4))
    return .success(
      IngestFrame(
        streamID: id, pcm: payload[headerLength...], seq: seq, sentAtEpochMs: sentAt))
  }

  // Read byte-wise rather than via `withUnsafeBytes`/`load`: the fields sit at
  // an offset determined by the stream-id length, so they are unaligned in
  // general and a typed load would trap on strict-alignment platforms.
  private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for i in (0..<4).reversed() { value = (value << 8) | UInt32(bytes[offset + i]) }
    return value
  }

  private static func readUInt64LE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[offset + i]) }
    return value
  }
}

/// What a stamped frame tells the capture layer. Separated from ``IngestFrame``
/// so nothing downstream of the socket has to know the wire encoding.
public struct IngestFrameStamp: Sendable, Equatable {
  public let seq: UInt32
  public let sentAtEpochMs: Double

  public init(seq: UInt32, sentAtEpochMs: Double) {
    self.seq = seq
    self.sentAtEpochMs = sentAtEpochMs
  }
}
