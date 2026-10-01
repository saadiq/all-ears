import EarsCore
import Testing

@testable import EarsMenuKit

@Suite("CalendarEnrichment")
struct CalendarEnrichmentTests {
  private func event(title: String, attendees: [CalendarAttendee]) -> CalendarEventInfo {
    CalendarEventInfo(
      title: title, start: instant(0), end: instant(3_600), matchText: "",
      attendees: attendees)
  }

  private let people = [
    CalendarAttendee(name: "Ada", isCurrentUser: false),
    CalendarAttendee(name: "Me", isCurrentUser: true),
  ]

  @Test("renames to the event title, then upserts attendees in event order")
  func renameThenAttendees() {
    let calls = CalendarEnrichment.calls(
      session: "s1", event: event(title: "Sync", attendees: people))
    #expect(
      calls == [
        .sessionRename(SessionRenameParams(session: "s1", title: "Sync")),
        .sessionAttendee(
          SessionAttendeeParams(
            session: "s1", id: "calendar-0", displayName: "Ada", origin: .calendar)),
        .sessionAttendee(
          SessionAttendeeParams(
            session: "s1", id: "calendar-1", displayName: "Me", origin: .calendar, isLocal: true)),
      ])
  }

  @Test("an untitled event renames nothing")
  func emptyTitleSkipsRename() {
    let calls = CalendarEnrichment.calls(session: "s1", event: event(title: "", attendees: people))
    #expect(calls.count == 2)
    for call in calls {
      guard case .sessionAttendee = call else {
        Issue.record("expected only attendee calls, got \(call)")
        return
      }
    }
  }

  @Test("only the current user is flagged self, and nobody is bound to a source")
  func selfAndNoSource() {
    let attendees = CalendarEnrichment.calls(
      session: "s1", event: event(title: "", attendees: people)
    ).compactMap { call -> SessionAttendeeParams? in
      if case .sessionAttendee(let params) = call { return params }
      return nil
    }
    #expect(attendees.map(\.id) == ["calendar-0", "calendar-1"])
    #expect(attendees.map(\.isLocal) == [nil, true])
    #expect(attendees.allSatisfy { $0.source == nil })
  }

  @Test("a failed enrichment says recording started, not that the start failed")
  func failureMessageKeepsTheRecording() {
    let message = CalendarEnrichment.failureMessage("unknown session")
    #expect(message.hasPrefix("Recording started"))
    #expect(message.contains("calendar details were not applied"))
    #expect(message.contains("unknown session"))
  }
}
