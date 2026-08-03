import Foundation
import Testing

@testable import EarsCore

/// Covers ``EventFrame``/``EarsEvent``: the v2 notification envelope
/// (`{"event", "params", "rev"}`), its two event classes (revision-tagged
/// state vs untagged telemetry), and per-kind param shapes.
@Suite("EventFrame")
struct EarsEventTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  private func decode(_ json: String) throws -> EventFrame {
    try JSONDecoder().decode(EventFrame.self, from: Data(json.utf8))
  }

  private func roundTrip(_ frame: EventFrame) throws -> EventFrame {
    let data = try JSONEncoder().encode(frame)
    return try JSONDecoder().decode(EventFrame.self, from: data)
  }

  @Test("decodes a vad telemetry event (no rev)")
  func decodesVAD() throws {
    let json = """
      {"event":"vad","params":{"source":"mic","state":"speech","t":"2026-07-17T10:30:02.14Z"}}
      """
    let frame = try decode(json)
    #expect(frame.event == .vad(source: "mic", state: .speech, t: base.advanced(by: 2.14)))
    #expect(frame.rev == nil)
  }

  @Test("decodes a source state event with its rev")
  func decodesSource() throws {
    let json = """
      {"event":"source","params":{"id":"mic","state":"paused"},"rev":43}
      """
    let frame = try decode(json)
    #expect(frame.event == .source(id: "mic", state: .paused))
    #expect(frame.rev == 43)
  }

  @Test("state kinds carry rev; telemetry kinds never do")
  func kindClasses() {
    #expect(EventKind.meeting.isState)
    #expect(EventKind.source.isState)
    #expect(!EventKind.vad.isState)
    #expect(!EventKind.segment.isState)
    #expect(!EventKind.job.isState)
  }

  @Test("only vad events are sourced for subscription filtering")
  func filterSource() {
    #expect(EarsEvent.vad(source: "mic", state: .speech, t: base).filterSource == "mic")
    #expect(EarsEvent.source(id: "mic", state: .paused).filterSource == nil)
    #expect(
      EarsEvent.job(JobPublishParams(job: "j", kind: "transcribe", state: .done)).filterSource
        == nil)
  }

  @Test("round-trips every case through encode/decode")
  func roundTrips() throws {
    let meeting = Meeting(
      id: "m1",
      identity: MeetingIdentity(platform: "meet", externalID: "abc"),
      title: "Weekly sync",
      state: .active,
      started: base,
      intervals: [MeetingInterval(start: base)],
      attendees: [
        MeetingAttendee(
          id: "spaces/x/devices/y", displayName: "Jane Doe", joined: base,
          source: "browser:meet:jane")
      ],
      sources: ["mic", "browser:meet:jane"],
      trigger: .browserExtension,
      rev: 43)
    let frames: [EventFrame] = [
      EventFrame(event: .vad(source: "mic", state: .speech, t: base.advanced(by: 2.14))),
      EventFrame(event: .meeting(meeting), rev: 43),
      EventFrame(event: .source(id: "mic", state: .capturing), rev: 44),
      EventFrame(
        event: .segment(
          SegmentPublishParams(
            meeting: "m1", speaker: "You", start: 604.1, end: 611.9,
            text: "Nothing from me, the deploy went out last night."))),
      EventFrame(
        event: .job(
          JobPublishParams(job: "j3", kind: "transcribe", meeting: "m1", state: .running))),
    ]
    for frame in frames {
      #expect(try roundTrip(frame) == frame)
    }
  }

  @Test("throws on an unrecognised event tag")
  func unrecognisedTag() {
    #expect(throws: (any Error).self) {
      try decode("{\"event\":\"mystery\",\"params\":{}}")
    }
  }
}
