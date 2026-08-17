import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("Calendar event matching")
struct CalendarMatchingTests {
  private func event(
    _ title: String, start: Double, end: Double, matchText: String = ""
  ) -> CalendarEventInfo {
    CalendarEventInfo(
      title: title, start: Instant(secondsSinceEpoch: start),
      end: Instant(secondsSinceEpoch: end), matchText: matchText, attendees: [])
  }

  @Test("an event overlapping now wins over one already over")
  func overlappingWins() {
    let match = CalendarMatching.best(
      events: [event("old", start: 0, end: 900), event("current", start: 1_000, end: 2_800)],
      now: Instant(secondsSinceEpoch: 1_500), platformMarker: nil)
    #expect(match?.title == "current")
  }

  @Test("joining early (inside the slack) still matches")
  func earlyJoinMatches() {
    let match = CalendarMatching.best(
      events: [event("upcoming", start: 2_000, end: 3_800)],
      now: Instant(secondsSinceEpoch: 1_500), platformMarker: nil)
    #expect(match?.title == "upcoming")
  }

  @Test("a platform marker breaks a tie between two overlapping events")
  func markerBreaksTie() {
    let match = CalendarMatching.best(
      events: [
        event("no-link", start: 1_000, end: 2_800),
        event("zoom-link", start: 1_000, end: 2_800, matchText: "https://zoom.us/j/123"),
      ],
      now: Instant(secondsSinceEpoch: 1_500), platformMarker: "zoom.us")
    #expect(match?.title == "zoom-link")
  }

  @Test("without a marker match the nearest start wins")
  func nearestStartWins() {
    let match = CalendarMatching.best(
      events: [event("long", start: 0, end: 7_200), event("near", start: 1_400, end: 2_800)],
      now: Instant(secondsSinceEpoch: 1_500), platformMarker: nil)
    #expect(match?.title == "near")
  }

  @Test("no candidate → nil")
  func noCandidates() {
    #expect(
      CalendarMatching.best(
        events: [event("done", start: 0, end: 900)],
        now: Instant(secondsSinceEpoch: 5_000), platformMarker: nil) == nil)
  }

  @Test("bundle ids resolve to platform markers")
  func markers() {
    #expect(CalendarMatching.marker(forBundleID: "us.zoom.xos") == "zoom.us")
    #expect(CalendarMatching.marker(forBundleID: "com.microsoft.teams2") == "teams.microsoft")
    #expect(CalendarMatching.marker(forBundleID: "com.example.other") == nil)
  }
}
