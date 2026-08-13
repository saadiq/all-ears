import Foundation
import Testing

@testable import EarsCore

/// The optional correlation `id` on the ingest contract: requests may carry
/// one (``IngestRequest``), and replies echo it verbatim beside the
/// `ok`/`data`/`error` envelope (``IngestReply``). Golden JSON on both
/// directions, plus the compatibility properties the field's optionality
/// exists for: an id-less request round-trips byte-identically to the
/// pre-id wire shape, and a reply with an id still decodes as a plain
/// ``ControlResponse`` for clients that never learned the field.
@Suite("Ingest correlation id")
struct IngestCorrelationIDTests {
  @Test("decodes an ingest.open carrying a correlation id")
  func decodesOpenWithID() throws {
    let json = """
      {"cmd":"ingest.open","id":"7","source":"browser:meet:jane","format":{"sample_rate":16000,"channels":1,"encoding":"pcm_s16le"}}
      """
    let request = try JSONDecoder().decode(IngestRequest.self, from: Data(json.utf8))
    #expect(request.correlationID == "7")
    guard case .open(let source, _, let session, let id) = request else {
      Issue.record("expected .open")
      return
    }
    #expect(source == "browser:meet:jane")
    #expect(session == nil)
    #expect(id == "7")
  }

  @Test("decodes ingest.close and ingest.attribution ids the same way")
  func decodesCloseAndAttributionIDs() throws {
    let close = try JSONDecoder().decode(
      IngestRequest.self, from: Data(#"{"cmd":"ingest.close","id":"8","stream_id":"s7"}"#.utf8))
    #expect(close == .close(streamID: "s7", id: "8"))

    let attribution = try JSONDecoder().decode(
      IngestRequest.self,
      from: Data(
        #"{"cmd":"ingest.attribution","id":"9","session":{"platform":"meet","external_id":"kQ0"},"events":[]}"#
          .utf8))
    #expect(attribution.correlationID == "9")
  }

  @Test("decodes the golden ingest.capture_failed shape")
  func decodesCaptureFailed() throws {
    let json =
      #"{"cmd":"ingest.capture_failed","id":"11","source":"browser:meet:t3","#
      + #""session":{"platform":"meet","external_id":"kQ0"},"reason":"decoder gave up"}"#
    let request = try JSONDecoder().decode(IngestRequest.self, from: Data(json.utf8))
    #expect(
      request
        == .captureFailed(
          source: "browser:meet:t3",
          session: SessionIdentity(platform: "meet", externalID: "kQ0"),
          reason: "decoder gave up", id: "11"))
  }

  @Test("a request without an id decodes with a nil correlation id — the pre-id shape")
  func decodesLegacyRequestWithoutID() throws {
    let request = try JSONDecoder().decode(
      IngestRequest.self, from: Data(#"{"cmd":"ingest.close","stream_id":"s7"}"#.utf8))
    #expect(request == .close(streamID: "s7", id: nil))
    #expect(request.correlationID == nil)
  }

  @Test("round-trips each command's id through encode/decode; nil stays absent")
  func roundTripsRequests() throws {
    let format = AudioFormatSpec(sampleRate: 16000, channels: 1, encoding: "pcm_s16le")
    let requests: [IngestRequest] = [
      .open(source: "browser:meet:jane", format: format, session: nil, id: "7"),
      .close(streamID: "s7", id: nil),
      .attribution(
        session: SessionIdentity(platform: "meet", externalID: "kQ0"), events: ["{}"], id: "9"),
      .captureFailed(
        source: "browser:meet:t3",
        session: SessionIdentity(platform: "meet", externalID: "kQ0"),
        reason: "decoder gave up", id: "11"),
    ]
    for request in requests {
      let data = try JSONEncoder().encode(request)
      #expect(try JSONDecoder().decode(IngestRequest.self, from: data) == request)
    }
    // The id-less encode emits no "id" key at all — old daemons see the old shape.
    let legacy = try JSONEncoder().encode(IngestRequest.close(streamID: "s7", id: nil))
    let keys = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any]).keys
    #expect(!keys.contains("id"))
  }

  @Test("IngestReply encodes the id flat beside ok/data, and omits it when nil")
  func replyEncodesIDFlat() throws {
    let withID = IngestReply(
      ControlResponse<IngestOpenData>.success(IngestOpenData(streamID: "s7")), id: "7")
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(withID)) as? [String: Any])
    #expect(object["ok"] as? Bool == true)
    #expect(object["id"] as? String == "7")
    #expect((object["data"] as? [String: Any])?["stream_id"] as? String == "s7")

    let withoutID = IngestReply(
      ControlResponse<IngestOpenData>.success(IngestOpenData(streamID: "s7")))
    let legacyObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(withoutID)) as? [String: Any])
    #expect(!legacyObject.keys.contains("id"))
  }

  @Test("decodes the golden reply shapes, success and failure")
  func replyDecodesGoldenShapes() throws {
    let success = try JSONDecoder().decode(
      IngestReply<IngestOpenData>.self,
      from: Data(#"{"ok":true,"id":"7","data":{"stream_id":"s7"}}"#.utf8))
    #expect(success == IngestReply(.success(IngestOpenData(streamID: "s7")), id: "7"))

    let failure = try JSONDecoder().decode(
      IngestReply<EmptyData>.self,
      from: Data(#"{"ok":false,"id":"7","error":"no live session"}"#.utf8))
    #expect(failure == IngestReply(.failure(ControlError("no live session")), id: "7"))
  }

  @Test("a reply carrying an id still decodes as a plain ControlResponse — old clients unaffected")
  func replyWithIDDecodesAsControlResponse() throws {
    let response = try JSONDecoder().decode(
      ControlResponse<IngestOpenData>.self,
      from: Data(#"{"ok":true,"id":"7","data":{"stream_id":"s7"}}"#.utf8))
    #expect(response == .success(IngestOpenData(streamID: "s7")))
  }
}
