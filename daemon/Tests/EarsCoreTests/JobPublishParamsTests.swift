import Foundation
import Testing

@testable import EarsCore

@Suite("JobPublishParams")
struct JobPublishParamsTests {
  @Test("a job without outputs encodes no outputs key")
  func omitsAbsentOutputs() throws {
    let params = JobPublishParams(job: "cleanup-1", kind: "cleanup", session: "s", state: .started)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params))
    let json = try #require(object as? [String: Any])
    #expect(json["outputs"] == nil)
  }

  @Test("outputs round-trip")
  func outputsRoundTrip() throws {
    let params = JobPublishParams(
      job: "summarize-1", kind: "summarize", session: "s", state: .done,
      outputs: ["/notes/a.summary.md", "/notes/a.actions.summary.md"])
    let decoded = try JSONDecoder().decode(
      JobPublishParams.self, from: JSONEncoder().encode(params))
    #expect(decoded == params)
  }

  @Test("a frame without outputs decodes to nil")
  func legacyFrameDecodes() throws {
    let legacy = #"{"job":"j","kind":"transcribe","state":"done"}"#
    let decoded = try JSONDecoder().decode(JobPublishParams.self, from: Data(legacy.utf8))
    #expect(decoded.outputs == nil)
  }
}
