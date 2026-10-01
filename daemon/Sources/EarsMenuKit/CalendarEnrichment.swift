import EarsCore

/// Turns the calendar event a detected meeting matched into the control
/// calls that annotate its session: a rename to the event's title, then one
/// roster upsert per attendee. The caller sends them in order and stops at
/// the first failure; earlier successes stand.
public enum CalendarEnrichment {
  /// Attendee ids are `calendar-<i>`, minted here, so a second enrichment of
  /// the same session upserts rather than duplicates. `self` is sent only for
  /// the current user and omitted otherwise, leaving the daemon's own
  /// inference alone. No attendee is bound to a source: an invitation says
  /// who was asked, not whose audio stream is whose.
  public static func calls(session: String, event: CalendarEventInfo) -> [ControlCall] {
    var calls: [ControlCall] = []
    if !event.title.isEmpty {
      calls.append(.sessionRename(SessionRenameParams(session: session, title: event.title)))
    }
    for (index, attendee) in event.attendees.enumerated() {
      calls.append(
        .sessionAttendee(
          SessionAttendeeParams(
            session: session, id: "calendar-\(index)", displayName: attendee.name,
            origin: .calendar, isLocal: attendee.isCurrentUser ? true : nil)))
    }
    return calls
  }
}
