import EarsCore

/// One attendee from a calendar event, as the EventKit shim maps it.
public struct CalendarAttendee: Sendable, Hashable {
  public var name: String
  public var isCurrentUser: Bool

  public init(name: String, isCurrentUser: Bool) {
    self.name = name
    self.isCurrentUser = isCurrentUser
  }
}

/// One calendar event, reduced to what matching and enrichment need.
/// `matchText` is the lowercased concatenation of the event's location,
/// notes, and URL — where a meeting link lives varies by inviter, so all
/// three are searched as one haystack.
public struct CalendarEventInfo: Sendable, Hashable {
  public var title: String
  public var start: Instant
  public var end: Instant
  public var matchText: String
  public var attendees: [CalendarAttendee]
  /// An all-day row ("PTO", "WFH", a birthday, a week-long conference).
  /// Never a meeting someone just joined — see ``CalendarMatching/best(events:now:platformMarker:)``.
  public var isAllDay: Bool

  public init(
    title: String, start: Instant, end: Instant, matchText: String,
    attendees: [CalendarAttendee], isAllDay: Bool = false
  ) {
    self.title = title
    self.start = start
    self.end = end
    self.matchText = matchText
    self.attendees = attendees
    self.isAllDay = isAllDay
  }
}

/// Picks the calendar event a just-detected meeting most plausibly is.
/// Candidates overlap now (with slack for joining early); an event whose
/// link/location carries the detected platform's marker wins outright;
/// otherwise the candidate whose start is nearest to now. Calendar data is a
/// garnish, never a gate: `nil` simply means the session starts unenriched.
///
/// All-day rows are excluded outright rather than ranked: "PTO", "WFH", a
/// birthday and a week-long conference all span *now*, so one would be a
/// candidate for every meeting of the day — and on a day with no other
/// event it wins by default, retitling the session and upserting a
/// birthday's guest list onto the roster.
public enum CalendarMatching {
  /// How early before an event's start a join still counts as that event.
  public static let joinSlackSeconds: Double = 600

  public static func marker(forBundleID bundleID: String) -> String? {
    KnownMeetingApp.matching(bundleID: bundleID)?.linkMarker
  }

  public static func best(
    events: [CalendarEventInfo], now: Instant, platformMarker: String?
  ) -> CalendarEventInfo? {
    let candidates = events.filter { event in
      !event.isAllDay && now >= event.start.advanced(by: -joinSlackSeconds) && now <= event.end
    }
    guard !candidates.isEmpty else { return nil }
    func markerMatches(_ event: CalendarEventInfo) -> Bool {
      guard let platformMarker else { return false }
      return event.matchText.contains(platformMarker)
    }
    return candidates.min { lhs, rhs in
      if markerMatches(lhs) != markerMatches(rhs) { return markerMatches(lhs) }
      let lhsDistance = abs(now.interval(since: lhs.start))
      let rhsDistance = abs(now.interval(since: rhs.start))
      if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
      return lhs.title < rhs.title
    }
  }
}
