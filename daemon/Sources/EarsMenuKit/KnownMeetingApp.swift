/// The native meeting apps detection recognises, and the two things the menu
/// bar derives from a watched bundle id: the `session.start` platform slug and
/// the marker this app's join links carry inside a calendar event.
///
/// One table rather than a switch per consumer — a new app is one entry, and
/// a slug can no longer exist for an app whose calendar marker was forgotten.
/// An unrecognised bundle id is not an error: detection still works from the
/// configured `app:*` source alone, only the calendar hint is unavailable.
public enum KnownMeetingApp: Sendable, CaseIterable {
  case zoom
  case teams

  /// Every bundle id this app has shipped under.
  public var bundleIDs: [String] {
    switch self {
    case .zoom: ["us.zoom.xos"]
    case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
    }
  }

  /// The `session.start` platform slug for a session this app triggered.
  public var platformSlug: String {
    switch self {
    case .zoom: "zoom-app"
    case .teams: "teams-app"
    }
  }

  /// The substring this app's join links carry, matched against a calendar
  /// event's location, notes, and URL.
  public var linkMarker: String {
    switch self {
    case .zoom: "zoom.us"
    case .teams: "teams.microsoft"
    }
  }

  public static func matching(bundleID: String) -> KnownMeetingApp? {
    allCases.first { $0.bundleIDs.contains(bundleID) }
  }
}
