import Foundation
import Testing

@testable import EarsCore

@Suite("StatusDashboardRendering")
struct StatusDashboardRenderingTests {
  private let utc = TimeZone(identifier: "UTC")!
  /// 2026-08-17T16:01:00Z.
  private let started = Instant(secondsSinceEpoch: 1_786_982_460)
  private var now: Instant { started.advanced(by: 26 * 60) }

  private func meeting() -> Session {
    Session(
      id: "3db61b03-aaaa-bbbb-cccc-ddddeeeeffff",
      identity: SessionIdentity(platform: "meet", externalID: "BSlbmiS0AI4B"),
      title: "Weekly Product Meeting",
      state: .active,
      started: started,
      attendees: [
        SessionAttendee(id: "you", displayName: "Tom", isLocal: true),
        SessionAttendee(
          id: "spaces/x/devices/1", displayName: "Matt Silva",
          source: SourceID("browser:meet:t1")),
      ] + (1...5).map { SessionAttendee(id: "spaces/x/devices/\($0 + 1)") },
      sources: ["mic", "browser:meet:t1", "browser:meet:t2", "browser:meet:t3"].map {
        SourceID($0)
      })
  }

  private func sources() -> [SourceStatus] {
    [
      SourceStatus(id: SourceID("mic"), state: .capturing, codec: "aac", bytesUsed: 9_904_279),
      SourceStatus(
        id: SourceID("browser:meet:t1"), state: .capturing, codec: "aac", bytesUsed: 4_161_098),
      SourceStatus(
        id: SourceID("browser:meet:t2"), state: .capturing, codec: "aac", bytesUsed: 2_600_000),
      SourceStatus(
        id: SourceID("browser:meet:t3"), state: .capturing, codec: "aac", bytesUsed: 2_600_000),
    ]
  }

  @Test("an active call renders grouped, labeled sources with speech evidence and a recent tail")
  func activeCallDashboard() {
    var recentArtifacts = SessionArtifacts()
    recentArtifacts.noteLink = "[[calls/x]]"
    let recent = SessionListEntry(
      session: Session(
        id: "9c00", title: "Michael Schwanzer", state: .ended,
        started: started.advanced(by: -3_600), ended: started.advanced(by: -1_800)),
      artifacts: recentArtifacts)

    let text = StatusDashboardRendering.render(
      StatusDashboardInputs(
        status: StatusData(
          uptimeSeconds: 1_577, sources: sources(), sessions: [meeting()]),
        evidenceBySession: [
          meeting().id: AttributionSpeechEvidence(speechCaptures: ["t1"])
        ],
        recent: [recent], configuredChain: OnEndStage.allCases),
      now: now, timeZone: utc)

    #expect(
      text == """
        earsd — up 26m, capturing

        ● Weekly Product Meeting  meet · 7 attendees · started 16:01 (26m ago)
            you (mic)        9.9 MB
            Matt Silva (t1)  4.2 MB  carrying speech
            t2, t3           5.2 MB  silent

        recent
          15:01  Michael Schwanzer  ✓ published
        """)
  }

  @Test("an unnamed speaking track is labeled remote audio, never by its source id alone")
  func unnamedSpeakingTrack() {
    var session = meeting()
    session.attendees = []
    let text = StatusDashboardRendering.render(
      StatusDashboardInputs(
        status: StatusData(uptimeSeconds: 60, sources: sources(), sessions: [session]),
        evidenceBySession: [session.id: AttributionSpeechEvidence(speechCaptures: ["t1"])],
        recent: [], configuredChain: OnEndStage.allCases),
      now: now, timeZone: utc)
    #expect(text.contains("remote audio (t1)  4.2 MB  carrying speech"))
    #expect(text.contains("t2, t3             5.2 MB  silent"))
  }

  @Test("with no attribution log, no speech or silence claim is made")
  func noEvidenceNoClaim() {
    let text = StatusDashboardRendering.render(
      StatusDashboardInputs(
        status: StatusData(uptimeSeconds: 60, sources: sources(), sessions: [meeting()]),
        evidenceBySession: [:],
        recent: [], configuredChain: OnEndStage.allCases),
      now: now, timeZone: utc)
    #expect(!text.contains("carrying speech"))
    #expect(!text.contains("silent"))
    #expect(text.contains("remote audio (t2)"))
  }

  @Test("an app source renders its meeting-activity label, not the raw source id")
  func appSourceRendersMeetingLabel() {
    let session = Session(
      id: "z1", identity: SessionIdentity(platform: "zoom", externalID: "123"),
      title: "Zoom Standup", state: .active, started: started,
      sources: ["mic", "app:us.zoom.xos"].map { SourceID($0) })
    let text = StatusDashboardRendering.render(
      StatusDashboardInputs(
        status: StatusData(
          uptimeSeconds: 60,
          sources: [
            SourceStatus(
              id: SourceID("mic"), state: .capturing, codec: "aac", bytesUsed: 1_000_000),
            SourceStatus(
              id: SourceID("app:us.zoom.xos"), state: .capturing, codec: "aac",
              bytesUsed: 2_000_000),
          ],
          sessions: [session],
          meetingActivity: [
            MeetingActivityStatus(
              source: SourceID("app:us.zoom.xos"), bundleID: "us.zoom.xos", label: "Zoom",
              active: true, episode: "e1")
          ]),
        evidenceBySession: [:],
        recent: [], configuredChain: OnEndStage.allCases),
      now: now, timeZone: utc)
    #expect(text.contains("Zoom"))
    #expect(!text.contains("app:us.zoom.xos"))
  }

  @Test("an app source with no meeting-activity row falls back to its raw source id")
  func appSourceFallsBackToRawID() {
    let session = Session(
      id: "z1", identity: SessionIdentity(platform: "zoom", externalID: "123"),
      title: "Zoom Standup", state: .active, started: started,
      sources: ["mic", "app:us.zoom.xos"].map { SourceID($0) })
    let text = StatusDashboardRendering.render(
      StatusDashboardInputs(
        status: StatusData(
          uptimeSeconds: 60,
          sources: [
            SourceStatus(
              id: SourceID("mic"), state: .capturing, codec: "aac", bytesUsed: 1_000_000),
            SourceStatus(
              id: SourceID("app:us.zoom.xos"), state: .capturing, codec: "aac",
              bytesUsed: 2_000_000),
          ],
          sessions: [session]),
        evidenceBySession: [:],
        recent: [], configuredChain: OnEndStage.allCases),
      now: now, timeZone: utc)
    #expect(text.contains("app:us.zoom.xos"))
  }

  @Test("an idle daemon renders its sources under a sources block")
  func idleDaemon() {
    let text = StatusDashboardRendering.render(
      StatusDashboardInputs(
        status: StatusData(
          uptimeSeconds: 11_160,
          sources: [
            SourceStatus(id: SourceID("mic"), state: .paused, codec: "aac", bytesUsed: 0)
          ],
          sessions: []),
        evidenceBySession: [:],
        recent: [], configuredChain: OnEndStage.allCases),
      now: now, timeZone: utc)
    #expect(
      text == """
        earsd — up 3h 6m, idle

        sources
          mic  paused
        """)
  }
}
