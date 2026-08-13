import Foundation
import Testing

@testable import EarsConfig
@testable import EarsCore

/// Round-trips `Session` through the `session.toml` (schema 3) mapping,
/// focused on the fields whose compatibility rules live in the TOML layer
/// rather than in the entity — above all `reconciler_version`, whose
/// absent-means-0 tolerance is what keeps every pre-versioning session file
/// readable (`docs/data-formats.md`, "Roster and speaker map").
@Suite("SessionDescriptorTOML")
struct SessionDescriptorTOMLTests {
  private static let started = Instant(secondsSinceEpoch: 1_784_284_200)  // 2026-07-17T10:30:00Z

  private static func referenceSession(reconcilerVersion: Int = 0) -> Session {
    Session(
      id: "0d5e7f6a-fixture",
      identity: SessionIdentity(platform: "meet", externalID: "abc-defg-hij"),
      title: "Weekly sync",
      state: .ended,
      started: started,
      ended: started.advanced(by: 1860),
      intervals: [SessionInterval(start: started, end: started.advanced(by: 1860))],
      attendees: [
        SessionAttendee(
          id: "spaces/x/devices/y", displayName: "Jane Doe", joined: started.advanced(by: 12),
          source: SourceID("browser:meet:jane-a1b2"))
      ],
      speakers: [
        SessionSpeaker(
          source: SourceID("browser:meet:jane-a1b2"), name: "Jane Doe", confidence: .correlated)
      ],
      sources: ["mic", "browser:meet:jane-a1b2"],
      trigger: .browserExtension,
      reconcilerVersion: reconcilerVersion)
  }

  @Test("reconciler_version round-trips beside the speaker map")
  func reconcilerVersionRoundTrips() throws {
    let encoded = SessionDescriptorTOML.encode(
      Self.referenceSession(reconcilerVersion: RosterReconciler.version))
    let decoded = try SessionDescriptorTOML.decode(encoded)

    #expect(decoded.reconcilerVersion == RosterReconciler.version)
    #expect(decoded == Self.referenceSession(reconcilerVersion: RosterReconciler.version))
  }

  @Test("a session.toml without reconciler_version decodes to version 0")
  func absentReconcilerVersionMeansZero() throws {
    // Exactly what encode produced before the field existed: strip it, as an
    // old file on disk simply never carried it.
    guard case .table(var table) = SessionDescriptorTOML.encode(Self.referenceSession()) else {
      Issue.record("encode did not produce a table")
      return
    }
    table.removeValue(forKey: "reconciler_version")

    let decoded = try SessionDescriptorTOML.decode(.table(table))
    #expect(decoded.reconcilerVersion == 0)
    // The rest of the record is untouched by the field's absence.
    #expect(decoded.speakers == Self.referenceSession().speakers)
  }
}
