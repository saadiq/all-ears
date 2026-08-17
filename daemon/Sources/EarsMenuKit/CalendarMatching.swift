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

  public init(
    title: String, start: Instant, end: Instant, matchText: String,
    attendees: [CalendarAttendee]
  ) {
    self.title = title
    self.start = start
    self.end = end
    self.matchText = matchText
    self.attendees = attendees
  }
}

/// Picks the calendar event a just-detected meeting most plausibly is.
/// Candidates overlap now (with slack for joining early); an event whose
/// link/location carries the detected platform's marker wins outright;
/// otherwise the candidate whose start is nearest to now. Calendar data is a
/// garnish, never a gate: `nil` simply means the session starts unenriched.
public enum CalendarMatching {
  /// How early before an event's start a join still counts as that event.
  public static let joinSlackSeconds: Double = 600

  public static func marker(forBundleID bundleID: String) -> String? {
    switch bundleID {
    case "us.zoom.xos": return "zoom.us"
    case "com.microsoft.teams2", "com.microsoft.teams": return "teams.microsoft"
    default: return nil
    }
  }

  public static func best(
    events: [CalendarEventInfo], now: Instant, platformMarker: String?
  ) -> CalendarEventInfo? {
    let candidates = events.filter { event in
      now.secondsSinceEpoch >= event.start.secondsSinceEpoch - joinSlackSeconds
        && now.secondsSinceEpoch <= event.end.secondsSinceEpoch
    }
    guard !candidates.isEmpty else { return nil }
    func markerMatches(_ event: CalendarEventInfo) -> Bool {
      guard let platformMarker else { return false }
      return event.matchText.contains(platformMarker)
    }
    return candidates.min { lhs, rhs in
      if markerMatches(lhs) != markerMatches(rhs) { return markerMatches(lhs) }
      let lhsDistance = abs(now.secondsSinceEpoch - lhs.start.secondsSinceEpoch)
      let rhsDistance = abs(now.secondsSinceEpoch - rhs.start.secondsSinceEpoch)
      if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
      return lhs.title < rhs.title
    }
  }
}
