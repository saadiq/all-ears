/// The ingest WebSocket's reply envelope: a ``ControlResponse`` plus the
/// request's optional correlation `id`, echoed verbatim at the top level:
///
/// ```jsonc
/// {"ok":true,"id":"7","data":{"stream_id":"s7"}}
/// {"ok":false,"id":"7","error":"<message>"}
/// ```
///
/// `id` is present exactly when the request carried one
/// (``IngestRequest/correlationID``), so a client that never sends ids sees
/// byte-for-byte the reply shape from before the field existed and keeps
/// matching replies to requests FIFO, while an id-sending client matches by
/// id and survives a reordered or unsolicited reply. The envelope encodes
/// flat — `id` sits beside `ok`/`data`/`error`, not nested — so decoding a
/// reply as a plain ``ControlResponse`` also still works (unknown keys are
/// ignored), which is what a pre-id client effectively does.
public struct IngestReply<Payload: Codable & Sendable & Hashable>: Sendable, Hashable {
  public var response: ControlResponse<Payload>
  public var id: String?

  public init(_ response: ControlResponse<Payload>, id: String? = nil) {
    self.response = response
    self.id = id
  }
}

extension IngestReply: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
  }

  public init(from decoder: any Decoder) throws {
    response = try ControlResponse<Payload>(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
  }

  public func encode(to encoder: any Encoder) throws {
    try response.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(id, forKey: .id)
  }
}
