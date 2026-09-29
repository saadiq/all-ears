import Foundation
import Testing

@testable import EarsCore

/// Covers the per-command response `data` payload types: ``StatusData``,
/// ``SourcesListData``, and ``IngestOpenData``.
@Suite("StatusData")
struct StatusDataTests {
  @Test("configured round-trips and uses the wire's snake_case")
  func configuredRoundTrips() throws {
    let status = StatusData(
      uptimeSeconds: 5, sources: [],
      configured: StatusData.Configured(
        sources: ["mic", "system"], onEndStages: ["transcribe", "cleanup"]))
    let data = try JSONEncoder().encode(status)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let configured = try #require(object?["configured"] as? [String: Any])
    #expect(configured["on_end_stages"] as? [String] == ["transcribe", "cleanup"])
    #expect(try JSONDecoder().decode(StatusData.self, from: data) == status)
  }

  @Test("a status from a daemon without configured decodes to nil and encodes nothing")
  func configuredIsAdditive() throws {
    let legacy = #"{"uptime_s":1,"sources":[],"sessions":[]}"#
    let decoded = try JSONDecoder().decode(StatusData.self, from: Data(legacy.utf8))
    #expect(decoded.configured == nil)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
    #expect((object as? [String: Any])?["configured"] == nil)
  }

  @Test("decodes the spec's literal status example")
  func decodesSpecExample() throws {
    let json = """
      {"uptime_s":3600,"sources":[{"id":"mic","state":"capturing","codec":"aac"}]}
      """
    let data = try JSONDecoder().decode(StatusData.self, from: Data(json.utf8))
    #expect(data.uptimeSeconds == 3600)
    #expect(data.sources == [SourceStatus(id: "mic", state: .capturing, codec: "aac")])
  }

  @Test("round-trips through encode/decode")
  func roundTrips() throws {
    let status = StatusData(
      uptimeSeconds: 42,
      sources: [
        SourceStatus(id: "mic", state: .capturing, codec: "aac"),
        SourceStatus(id: "app:us.zoom.xos", state: .paused, codec: "aac", bytesUsed: 2048),
      ])
    let data = try JSONEncoder().encode(status)
    let decoded = try JSONDecoder().decode(StatusData.self, from: data)
    #expect(decoded == status)
  }
}

@Suite("SourcesListData")
struct SourcesListDataTests {
  @Test("round-trips through encode/decode")
  func roundTrips() throws {
    let list = SourcesListData(sources: [
      SourceStatus(id: "mic", state: .capturing, codec: "aac")
    ])
    let data = try JSONEncoder().encode(list)
    let decoded = try JSONDecoder().decode(SourcesListData.self, from: data)
    #expect(decoded == list)
  }
}

@Suite("IngestOpenData")
struct IngestOpenDataTests {
  @Test("decodes the spec's literal stream_id example")
  func decodesSpecExample() throws {
    let json = """
      {"stream_id":"s7"}
      """
    let data = try JSONDecoder().decode(IngestOpenData.self, from: Data(json.utf8))
    #expect(data == IngestOpenData(streamID: "s7"))
  }
}
