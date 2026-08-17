import Testing

@testable import EarsCore

@Suite("AttributionBindingHints")
struct AttributionBindingHintsTests {

  private static let boundLine = """
    {"schema":1,"type":"provisional-binding","t":1723500000100,"trackId":"trk-9",\
    "deviceId":"spaces/s/devices/9","correlator":"dom","confirmations":2,"outcome":"bound"}
    """
  private static let linkLine = """
    {"schema":1,"type":"identity-link","t":1723500000200,"trackId":"trk-9",\
    "captureId":"t3","participantId":"spaces/s/devices/9"}
    """

  @Test("an identity-link joins to the provisional-binding that caused it")
  func joinsLinkToBindingCause() {
    let hints = AttributionBindingHints.parse(
      jsonl: [Self.boundLine, Self.linkLine].joined(separator: "\n"))

    #expect(
      hints == [
        AttributionBindingHint(
          captureId: "t3", attendeeID: "spaces/s/devices/9", trackId: "trk-9",
          t: 1_723_500_000_200, correlator: "dom", confirmations: 2)
      ])
  }

  @Test("an admission-time link has no binding event and no correlator cause")
  func admissionLinkStandsAlone() {
    let hints = AttributionBindingHints.parse(jsonl: Self.linkLine)

    #expect(hints.count == 1)
    #expect(hints[0].correlator == nil)
    #expect(hints[0].confirmations == nil)
    #expect(hints[0].attendeeID == "spaces/s/devices/9")
  }

  @Test("a refused binding never becomes a cause — only bound outcomes join")
  func refusedBindingsDoNotJoin() {
    let refused = """
      {"schema":1,"type":"provisional-binding","t":1723500000100,"trackId":"trk-9",\
      "deviceId":"spaces/s/devices/9","correlator":"dom","confirmations":2,\
      "outcome":"refused-rebind"}
      """
    let hints = AttributionBindingHints.parse(
      jsonl: [refused, Self.linkLine].joined(separator: "\n"))

    #expect(hints.count == 1)
    #expect(hints[0].correlator == nil)
  }

  @Test("repeat links for the same pair collapse to the first")
  func dedupesRepeatLinks() {
    let repeatLink = """
      {"schema":1,"type":"identity-link","t":1723500009999,"trackId":"trk-9",\
      "captureId":"t3","participantId":"spaces/s/devices/9"}
      """
    let hints = AttributionBindingHints.parse(
      jsonl: [Self.linkLine, repeatLink].joined(separator: "\n"))

    #expect(hints.count == 1)
    #expect(hints[0].t == 1_723_500_000_200)
  }

  @Test("foreign lines, bad JSON, and unknown schemas are skipped, never guessed")
  func skipsForeignLines() {
    let noise = [
      "not json at all",
      "{\"schema\":2,\"type\":\"identity-link\",\"t\":1,\"trackId\":\"x\",\"captureId\":\"y\",\"participantId\":\"z\"}",
      "{\"schema\":1,\"type\":\"track-appeared\",\"t\":1,\"trackId\":\"x\"}",
      "{\"schema\":1,\"type\":\"identity-link\",\"t\":1}",  // missing fields
      "",
      Self.linkLine,
    ]
    let hints = AttributionBindingHints.parse(jsonl: noise.joined(separator: "\n"))

    #expect(hints.count == 1)
    #expect(hints[0].captureId == "t3")
  }

  @Test("speechEvidence collects onset captures and burst counts, skipping noise")
  func speechEvidenceParses() {
    let lines = [
      #"{"schema":1,"type":"audio-onset","t":1,"participantId":"t1","trackId":"trk-1","state":"start","framePeak":0.01}"#,
      #"{"schema":1,"type":"audio-onset","t":2,"participantId":"t1","trackId":"trk-1","state":"stop","framePeak":0.0}"#,
      #"{"schema":1,"type":"dom-burst","t":3,"deviceId":"spaces/s/devices/9"}"#,
      #"{"schema":1,"type":"dom-burst","t":4,"deviceId":"spaces/s/devices/9"}"#,
      #"{"schema":1,"type":"dom-burst","t":5,"deviceId":"spaces/s/devices/7"}"#,
      #"{"schema":2,"type":"audio-onset","t":6,"participantId":"future"}"#,  // unknown schema
      "not json at all",
      #"{"schema":1,"type":"track-appeared","t":7,"trackId":"trk-2"}"#,
    ]
    let evidence = AttributionBindingHints.speechEvidence(jsonl: lines.joined(separator: "\n"))

    #expect(evidence.speechCaptures == ["t1"])
    #expect(evidence.burstCounts == ["spaces/s/devices/9": 2, "spaces/s/devices/7": 1])
  }

  @Test("bound-late-rename is a cause too — the track died before confirming")
  func lateRenameBindingJoins() {
    let late = """
      {"schema":1,"type":"provisional-binding","t":1723500000100,"trackId":"trk-9",\
      "deviceId":"spaces/s/devices/9","correlator":"unmute","confirmations":3,\
      "outcome":"bound-late-rename"}
      """
    let hints = AttributionBindingHints.parse(jsonl: [late, Self.linkLine].joined(separator: "\n"))

    #expect(hints.first?.correlator == "unmute")
    #expect(hints.first?.confirmations == 3)
  }
}
